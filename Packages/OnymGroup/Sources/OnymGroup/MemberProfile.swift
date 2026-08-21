import Foundation

/// View-facing directory entry for one peer the local user has
/// interacted with through a group. Carries what the UI needs to
/// render "X joined" / "you are talking to Y" without crossing into
/// secret material. Stored on `ChatGroup.memberProfiles` keyed by
/// the peer's lowercase BLS pubkey hex.
///
/// Distinct from `GovernanceMember`: that's the on-chain Merkle-tree
/// roster (V1: creator only, static). `MemberProfile` covers the
/// app-level "who's in this conversation" set, which V1 grows as
/// joiners are admitted even though the on-chain roster doesn't
/// change.
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
public struct MemberProfile: Codable, Equatable, Hashable, Sendable {
    public let alias: String
    public let inboxPublicKey: Data
    /// 32-byte Ed25519 raw public key (`Identity.stellarPublicKey`).
    /// Same key that signs every `SealedEnvelope` — the chat dispatcher
    /// (PR 4) verifies an incoming chat message's envelope signature
    /// against this so an insider can't forge another member's
    /// `senderBlsPubkeyHex` claim.
    public let sendingPubkey: Data
    /// 32-byte `SHA256` of the rules this member agreed to when they
    /// asked to join, and their 64-byte Ed25519 signature over
    /// `GroupRules.statement(...)`. Both nil for a member who joined
    /// before the group had rules, or from a build that predates them.
    ///
    /// Kept on the member rather than on the request, because the
    /// request is consumed at approval and the question ("did they
    /// agree?") outlives it by the whole life of the membership.
    ///
    /// Announced alongside the rest of the profile, so any member can
    /// check any other member's agreement against `sendingPubkey` —
    /// the founder who admitted them is not a required witness. The
    /// text those bytes cover is the group's own
    /// `ChatGroup.invitationMessage`; keeping the hash is what would
    /// expose a later divergence between the two rather than quietly
    /// failing to verify.
    public let rulesHash: Data?
    public let rulesSignature: Data?

    enum CodingKeys: String, CodingKey {
        case alias
        case inboxPublicKey = "inbox_public_key"
        case sendingPubkey = "sending_pubkey"
        case rulesHash = "rules_hash"
        case rulesSignature = "rules_signature"
    }

    public init(
        alias: String,
        inboxPublicKey: Data,
        sendingPubkey: Data,
        rulesHash: Data? = nil,
        rulesSignature: Data? = nil
    ) {
        self.alias = alias
        self.inboxPublicKey = inboxPublicKey
        self.sendingPubkey = sendingPubkey
        self.rulesHash = rulesHash
        self.rulesSignature = rulesSignature
    }

    /// The wire-side decode boundary. `MemberProfile` ships inside
    /// `GroupInvitationPayload.memberProfiles` and
    /// `MemberAnnouncementPayload` (via the dispatcher's profile
    /// merge), so a wrong-sized key on the wire becomes a bogus
    /// verification key for PR 4. Validate at decode — same pattern
    /// as `MemberAnnouncementPayload.AnnouncedMember`.
    public init(from decoder: Decoder) throws {
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
        let rulesHash = try c.decodeIfPresent(Data.self, forKey: .rulesHash)
        let rulesSignature = try c.decodeIfPresent(Data.self, forKey: .rulesSignature)
        // Wrong-sized agreement bytes are dropped, not thrown on. A
        // malformed signature means "we can't show this member agreed",
        // which is already what nil means — and rejecting the whole
        // profile over it would take a member's inbox and verification
        // keys down with it, breaking the chat for a field that only
        // ever adds evidence.
        let sizedHash = rulesHash?.count == 32 ? rulesHash : nil
        let sizedSignature = rulesSignature?.count == 64 ? rulesSignature : nil
        self.alias = alias
        self.inboxPublicKey = inbox
        self.sendingPubkey = sending
        self.rulesHash = sizedSignature == nil ? nil : sizedHash
        self.rulesSignature = sizedHash == nil ? nil : sizedSignature
    }
}

public enum MemberProfileError: Error, Equatable {
    case shape(String)
}
