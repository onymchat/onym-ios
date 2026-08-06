import Foundation
import CryptoKit

/// Mints fresh per-invite X25519 keypairs and persists them via
/// `IntroKeyStore`. Returns an `IntroCapability` (the public-facing
/// deeplink payload) — the caller drops it into a deeplink URL and
/// shares.
///
/// **Threading**: actor-isolated. Keypair generation is microseconds;
/// the Keychain write is the dominant cost (single `SecItemUpdate`).
/// Cheap enough for the foreground tap handler to await directly.
///
/// **Two entry points, deliberately**:
///  - `currentOrMint` — the shared-link path. Hands back the
///    identity's existing live key for the group when there is one,
///    minting only when there isn't. Invite links are multi-use and
///    do not expire: one keypair serves every joiner who redeems the
///    link until the inviter revokes it, so re-opening the share
///    screen must return the same link rather than stacking a fresh
///    relay REQ slot per visit.
///  - `mint` — always a fresh keypair. `CreateGroupInteractor`'s
///    create-time offers want one key per invitee so an inbound join
///    request maps 1:1 back to the person the admin meant to invite.
///
/// **Why a keypair per link instead of one per identity**: the intro
/// key is the only thing that can decrypt requests aimed at it, so
/// scoping it to one group means a leaked link exposes that group's
/// request channel and nothing else — and revoking it retires that
/// one link without touching any other invite.
actor InviteIntroducer {
    private let store: any IntroKeyStore
    private let now: @Sendable () -> Date

    init(store: any IntroKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Mint a fresh intro keypair, persist it, and return the
    /// `IntroCapability` the caller will pack into a deeplink URL.
    ///
    /// - Parameters:
    ///   - ownerIdentityID: the identity that's inviting. Used for
    ///     cascade-delete when the identity is removed.
    ///   - groupId: the on-chain `group_id` the invite is for.
    ///     Must be 32 bytes — throws `IntroducerError.invalidGroupID`
    ///     otherwise.
    ///   - groupName: optional plaintext name surfaced in the deeplink
    ///     for the joiner's preview. Pass nil for groups whose name
    ///     is sensitive (deeplink transits cleartext channels).
    ///   - label: nil for the group's shared link; the invitee's
    ///     alias or key fingerprint for a create-time offer, so the
    ///     invite list can name the row.
    func mint(
        ownerIdentityID: IdentityID,
        groupId: Data,
        groupName: String? = nil,
        label: String? = nil
    ) async throws -> IntroCapability {
        guard groupId.count == 32 else {
            throw IntroducerError.invalidGroupID(actualSize: groupId.count)
        }

        // CryptoKit handles X25519 scalar clamping internally.
        // `.rawRepresentation` returns the canonical 32-byte form
        // for both the secret scalar and the curve point.
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let pubBytes = priv.publicKey.rawRepresentation
        let privBytes = priv.rawRepresentation

        await store.save(IntroKeyEntry(
            introPublicKey: pubBytes,
            introPrivateKey: privBytes,
            ownerIdentityID: ownerIdentityID,
            groupId: groupId,
            createdAt: now(),
            label: label
        ))

        return try IntroCapability(
            introPublicKey: pubBytes,
            groupId: groupId,
            groupName: groupName
        )
    }

    /// The group's current invite capability for `ownerIdentityID`,
    /// minting one only when the group has no link yet.
    ///
    /// Invite links are multi-use and never expire, so the share screen
    /// is a view onto the group's live link rather than a link factory:
    /// re-entering it must surface the same link instead of leaving a
    /// trail of live intro slots, each costing a relay REQ slot for as
    /// long as it exists. Rotating is an explicit user action —
    /// `rotate`, behind "Generate new link".
    ///
    /// Scoped to `ownerIdentityID` on purpose: `IntroInboxPump` is
    /// wired to `entriesStream(forOwner: activeID)`, so it only listens
    /// on the *active* identity's intro inboxes. Handing back a key
    /// another identity minted would produce a link nobody is
    /// subscribed to. Two identities sharing one group each get their
    /// own key; that's correct, not duplication.
    ///
    /// - Note: `store.listForOwner` is contractually newest-first, so
    ///   the first match is the freshest key for the group.
    func currentOrMint(
        ownerIdentityID: IdentityID,
        groupId: Data,
        groupName: String? = nil
    ) async throws -> IntroCapability {
        // Checked ahead of the store read so a malformed id can't cause
        // a pointless `listForOwner` pass, and so the throw is the same
        // whichever branch would have run.
        guard groupId.count == 32 else {
            throw IntroducerError.invalidGroupID(actualSize: groupId.count)
        }

        // `label == nil` is the shared link. Offer keys are minted for
        // one named invitee and must never be handed out as the group's
        // link — the common create-with-invitees flow lands on the
        // share screen with the last invitee's key as the newest entry.
        let live = await store.listForOwner(ownerIdentityID).first {
            $0.groupId == groupId && $0.label == nil
        }
        if let live {
            return try IntroCapability(
                introPublicKey: live.introPublicKey,
                groupId: groupId,
                groupName: groupName
            )
        }

        return try await mint(
            ownerIdentityID: ownerIdentityID,
            groupId: groupId,
            groupName: groupName
        )
    }

    /// Replace the group's shared link: mint a fresh keypair, then
    /// revoke every other key this identity holds for the group.
    ///
    /// This is what "Generate new link" does. Since links no longer
    /// expire, rotating is the only way a leaked or over-shared link
    /// stops working — and rotating rather than plain-revoking leaves
    /// the inviter with a link they can still hand out.
    ///
    /// Mint-then-revoke, not the reverse: if the process dies between
    /// the two, the group is left with two working links rather than
    /// none. An extra live link is a nuisance the user can rotate
    /// again; zero links with a joiner mid-flow is a dead end.
    ///
    /// Revocation is local. There is no way to tell the relay or the
    /// people holding the old link — they simply stop being able to
    /// reach anyone, because this device stops subscribing to that
    /// intro tag and is the only holder of the private key.
    @discardableResult
    func rotate(
        ownerIdentityID: IdentityID,
        groupId: Data,
        groupName: String? = nil
    ) async throws -> IntroCapability {
        guard groupId.count == 32 else {
            throw IntroducerError.invalidGroupID(actualSize: groupId.count)
        }

        // Only the shared link rotates. Per-invitee offer keys are
        // revoked individually from the invite list.
        let superseded = await store.listForOwner(ownerIdentityID)
            .filter { $0.groupId == groupId && $0.label == nil }
            .map(\.introPublicKey)

        let fresh = try await mint(
            ownerIdentityID: ownerIdentityID,
            groupId: groupId,
            groupName: groupName
        )

        for pub in superseded where pub != fresh.introPublicKey {
            await store.revoke(introPublicKey: pub)
        }
        return fresh
    }

    /// Kill one specific link. Used by the per-row revoke on the
    /// invite list — chiefly for the create-time offer keys, which
    /// have no other way to be retired now that nothing expires.
    func revoke(introPublicKey: Data) async {
        await store.revoke(introPublicKey: introPublicKey)
    }

    /// Every live invite this identity holds for the group,
    /// newest-first. Backs the invite list on the share screen.
    func liveInvites(
        ownerIdentityID: IdentityID,
        groupId: Data
    ) async -> [IntroKeyEntry] {
        await store.listForOwner(ownerIdentityID).filter { $0.groupId == groupId }
    }
}

enum IntroducerError: Error, Equatable {
    case invalidGroupID(actualSize: Int)
}
