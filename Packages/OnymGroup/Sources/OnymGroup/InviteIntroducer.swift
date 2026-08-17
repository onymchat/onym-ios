import Foundation
import CryptoKit
import OnymIdentity

/// Mints fresh per-invite X25519 keypairs and persists them via
/// `IntroKeyStore`. Returns an `IntroCapability` (the public-facing
/// deeplink payload) — the caller drops it into a deeplink URL and
/// shares.
///
/// **Threading**: actor-isolated. Keypair generation is microseconds;
/// the Keychain write is the dominant cost (single `SecItemUpdate`).
/// Cheap enough for the foreground tap handler to await directly.
///
/// **Why one keypair per invite instead of one per identity**: per-
/// link revocation. The inviter can stop listening on a specific
/// intro tag → that link goes silent without affecting other
/// outstanding invites. A leaked link only burns its own slot.
///
/// `currentOrMint` reuses the group's shared link; `mint` is always
/// fresh, for create-time offers needing one key per invitee.
public actor InviteIntroducer {
    private let store: any IntroKeyStore
    private let now: @Sendable () -> Date
    /// In-flight shared-link mutation per group: both paths read the
    /// store across an `await`, so the actor suspends between them.
    private var inFlight: [String: Task<IntroCapability, Error>] = [:]

    public init(store: any IntroKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
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
    ///   - label: nil for the shared link; the invitee's fingerprint
    ///     for a create-time offer, so the invite list can name it.
    public func mint(
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

    /// The group's shared link, minting only when it has none. Owner-
    /// scoped: the pump only listens on the active identity's inboxes.
    public func currentOrMint(
        ownerIdentityID: IdentityID,
        groupId: Data,
        groupName: String? = nil
    ) async throws -> IntroCapability {
        // Ahead of the store read so the throw is the same whichever
        // branch would have run.
        guard groupId.count == 32 else {
            throw IntroducerError.invalidGroupID(actualSize: groupId.count)
        }
        return try await serializingLink(ownerIdentityID, groupId) {
            // `label == nil` is the shared link. Create-with-invitees
            // would otherwise hand out the last invitee's offer key.
            // `isLegacy` excludes rows written before labels existed —
            // they are also `label == nil`, and the newest of them on
            // such a group IS that last invitee's private offer key.
            let live = await self.store.listForOwner(ownerIdentityID).first {
                $0.groupId == groupId && $0.label == nil && !$0.isLegacy
            }
            if let live {
                return try IntroCapability(
                    introPublicKey: live.introPublicKey,
                    groupId: groupId,
                    groupName: groupName
                )
            }
            return try await self.mint(
                ownerIdentityID: ownerIdentityID,
                groupId: groupId,
                groupName: groupName
            )
        }
    }

    /// Serialize the read-decide-write on a group's shared link, which
    /// actor isolation alone doesn't cover across the store `await`.
    private func serializingLink(
        _ owner: IdentityID,
        _ groupId: Data,
        _ body: @escaping @Sendable () async throws -> IntroCapability
    ) async throws -> IntroCapability {
        let key = owner.rawValue.uuidString + ":"
            + groupId.map { String(format: "%02x", $0) }.joined()
        // Wait out any predecessor; its failure is not ours to handle.
        while let running = inFlight[key] {
            _ = try? await running.value
            if inFlight[key] == running { inFlight[key] = nil }
        }
        let task = Task { try await body() }
        inFlight[key] = task
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        return try await task.value
    }

    /// "Generate new link": mint fresh, then revoke the old shared key.
    /// That order, so a crash leaves two working links rather than none.
    @discardableResult
    public func rotate(
        ownerIdentityID: IdentityID,
        groupId: Data,
        groupName: String? = nil
    ) async throws -> IntroCapability {
        guard groupId.count == 32 else {
            throw IntroducerError.invalidGroupID(actualSize: groupId.count)
        }
        return try await serializingLink(ownerIdentityID, groupId) {
            // Only the shared link rotates; offer keys are revoked one
            // at a time from the invite list.
            // Legacy rows are excluded for the same reason: rotating
            // the shared link must not silently kill every outstanding
            // pre-upgrade invite.
            let superseded = await self.store.listForOwner(ownerIdentityID)
                .filter { $0.groupId == groupId && $0.label == nil && !$0.isLegacy }
                .map(\.introPublicKey)

            let fresh = try await self.mint(
                ownerIdentityID: ownerIdentityID,
                groupId: groupId,
                groupName: groupName
            )

            for pub in superseded where pub != fresh.introPublicKey {
                await self.store.revoke(introPublicKey: pub)
            }
            return fresh
        }
    }

    /// Kill one link. Backs the per-row revoke, chiefly for offer keys
    /// which have no other way to be retired.
    public func revoke(introPublicKey: Data) async {
        await store.revoke(introPublicKey: introPublicKey)
    }

    /// Every live invite this identity holds for the group,
    /// newest-first. Backs the invite list on the share screen.
    public func liveInvites(
        ownerIdentityID: IdentityID,
        groupId: Data
    ) async -> [IntroKeyEntry] {
        // Sorted here rather than relying on the store: newest-first is
        // `KeychainIntroKeyStore`'s behaviour, not an `IntroKeyStore`
        // guarantee, and the in-memory double doesn't sort.
        await store.listForOwner(ownerIdentityID)
            .filter { $0.groupId == groupId }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

public enum IntroducerError: Error, Equatable {
    case invalidGroupID(actualSize: Int)
}
