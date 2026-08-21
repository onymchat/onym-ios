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
    /// The rules text the group held when this member was admitted —
    /// the bytes the signature covers.
    ///
    /// Retained rather than pointed at. `GroupRules`' own doc is the
    /// argument: a signature is evidence only if the bytes it covers
    /// can be produced again, and a hash beside a *live*
    /// `ChatGroup.invitationMessage` proves that something was agreed
    /// and never what — one edit and every retained agreement becomes
    /// unattributable to any text on the device.
    ///
    /// It is the admitting device's own copy, never the joiner's: the
    /// request deliberately doesn't carry the text, because a joiner
    /// who supplied it would be choosing what their own signature is
    /// checked against.
    public let rulesText: String?

    enum CodingKeys: String, CodingKey {
        case alias
        case inboxPublicKey = "inbox_public_key"
        case sendingPubkey = "sending_pubkey"
        case rulesHash = "rules_hash"
        case rulesSignature = "rules_signature"
        case rulesText = "rules_text"
    }

    public init(
        alias: String,
        inboxPublicKey: Data,
        sendingPubkey: Data,
        rulesHash: Data? = nil,
        rulesSignature: Data? = nil,
        rulesText: String? = nil
    ) {
        self.alias = alias
        self.inboxPublicKey = inboxPublicKey
        self.sendingPubkey = sendingPubkey
        // Validated here too, not only at decode. The memberwise init
        // is how the local roster is written, so without this a
        // malformed pair could be persisted that the wire would have
        // refused — the two paths should not disagree about what
        // counts as evidence.
        let paired = Self.paired(hash: rulesHash, signature: rulesSignature)
        self.rulesHash = paired.hash
        self.rulesSignature = paired.signature
        self.rulesText = paired.hash == nil ? nil : GroupRules.normalized(rulesText)
    }

    /// Wrong-sized or half-present agreement bytes become no agreement.
    /// "We can't show they agreed" is what nil already means, and
    /// rejecting the profile over it would cost a member their inbox
    /// and verification keys for a field that only adds evidence.
    static func paired(hash: Data?, signature: Data?) -> (hash: Data?, signature: Data?) {
        guard hash?.count == 32, signature?.count == 64 else { return (nil, nil) }
        return (hash, signature)
    }

    /// Whether this member's stored agreement checks out against the
    /// text stored with it — the question the retained bytes exist to
    /// answer, asked in one place so no caller has to reassemble it.
    ///
    /// Verifiable by any member, not only the founder who admitted
    /// them: `sendingPubkey` is announced to everyone.
    public func agreedToRules(groupID: Data) -> Bool {
        guard let rulesSignature, let rulesText else { return false }
        return GroupRules.isAgreement(
            signature: rulesSignature,
            rules: rulesText,
            groupID: groupID,
            joinerSendingPublicKey: sendingPubkey
        )
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
        let paired = Self.paired(
            hash: try c.decodeIfPresent(Data.self, forKey: .rulesHash),
            signature: try c.decodeIfPresent(Data.self, forKey: .rulesSignature)
        )
        self.alias = alias
        self.inboxPublicKey = inbox
        self.sendingPubkey = sending
        self.rulesHash = paired.hash
        self.rulesSignature = paired.signature
        self.rulesText = paired.hash == nil
            ? nil
            : GroupRules.normalized(try c.decodeIfPresent(String.self, forKey: .rulesText))
    }
}

public enum MemberProfileError: Error, Equatable {
    case shape(String)
}
