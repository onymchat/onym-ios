import Foundation

/// View-facing directory entry for one peer the local user has
/// interacted with through a group. Carries what the UI needs to
/// render "X joined" / "you are talking to Y" without crossing into
/// secret material. Stored on `ChatGroup.memberProfiles` keyed by
/// the peer's lowercase BLS pubkey hex.
///
/// Distinct from `GovernanceMember`: that's the on-chain Merkle-tree
/// roster (advanced by the admin's `update_commitment` as joiners are
/// admitted / members are removed). `MemberProfile` covers the
/// app-level "who's in this conversation" set — aliases and inbox
/// keys the cryptographic roster doesn't carry.
///
/// Trust: `alias` is self-asserted by its owner — never load-bearing.
/// Surfaces should always offer the member's BLS-pubkey fingerprint
/// alongside (matches the inviter-approval pattern documented on
/// `JoinRequestPayload`).
///
/// `inboxPublicKey` is the 32-byte X25519 raw pub. Persisted so the
/// admin (or any authorized fanout sender, in future governance
/// models) can reach every member's inbox to announce roster changes
/// without re-deriving from the join request each time.
struct MemberProfile: Codable, Equatable, Hashable, Sendable {
    let alias: String
    let inboxPublicKey: Data
    /// 32-byte Ed25519 raw public key (`Identity.stellarPublicKey`).
    /// Same key that signs every `SealedEnvelope` — the chat dispatcher
    /// (PR 4) verifies an incoming chat message's envelope signature
    /// against this so an insider can't forge another member's
    /// `senderBlsPubkeyHex` claim.
    let sendingPubkey: Data
    /// Tombstone for a member removed from the group. A revoked
    /// profile stays in the map so past-message alias rendering and
    /// BLS-fingerprint lookups keep working, but every trust surface
    /// treats the member as gone: sender-auth paths reject their
    /// envelopes, fanout loops skip their inbox, and the members UI
    /// hides the row. Decoded with `decodeIfPresent ?? false` so
    /// legacy persisted JSON and pre-removal wire payloads decode as
    /// active members; always encoded (Android decoders default the
    /// same way). Mirrors `MemberProfile.revoked` from onym-android.
    let revoked: Bool

    enum CodingKeys: String, CodingKey {
        case alias
        case inboxPublicKey = "inbox_public_key"
        case sendingPubkey = "sending_pubkey"
        case revoked
    }

    init(alias: String, inboxPublicKey: Data, sendingPubkey: Data, revoked: Bool = false) {
        self.alias = alias
        self.inboxPublicKey = inboxPublicKey
        self.sendingPubkey = sendingPubkey
        self.revoked = revoked
    }

    /// The wire-side decode boundary. `MemberProfile` ships inside
    /// `GroupInvitationPayload.memberProfiles` and
    /// `MemberAnnouncementPayload` (via the dispatcher's profile
    /// merge), so a wrong-sized key on the wire becomes a bogus
    /// verification key for PR 4. Validate at decode — same pattern
    /// as `MemberAnnouncementPayload.AnnouncedMember`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let alias = try c.decode(String.self, forKey: .alias)
        let inbox = try c.decode(Data.self, forKey: .inboxPublicKey)
        let sending = try c.decode(Data.self, forKey: .sendingPubkey)
        guard inbox.count == 32 else {
            throw MemberProfileError.shape(
                "inboxPublicKey: expected 32 bytes, got \(inbox.count)"
            )
        }
        guard sending.count == 32 else {
            throw MemberProfileError.shape(
                "sendingPubkey: expected 32 bytes, got \(sending.count)"
            )
        }
        self.alias = alias
        self.inboxPublicKey = inbox
        self.sendingPubkey = sending
        self.revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
    }

    /// Copy of this profile with the tombstone flipped. Value-type
    /// mirror of Android's `copy(revoked = true)` — the apply paths
    /// tombstone in place, never delete.
    func withRevoked(_ revoked: Bool) -> MemberProfile {
        MemberProfile(
            alias: alias,
            inboxPublicKey: inboxPublicKey,
            sendingPubkey: sendingPubkey,
            revoked: revoked
        )
    }
}

enum MemberProfileError: Error, Equatable {
    case shape(String)
}
