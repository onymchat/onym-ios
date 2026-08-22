import Foundation

/// Inner plaintext of the sealed envelope a joiner sends to an
/// inviter's intro inbox. Carries everything the inviter's app
/// needs to ship the actual sealed `GroupInvitationPayload` back:
///
///  - `joinerInboxPublicKey` — where the sealed invitation will be
///    posted (the joiner's identity inbox X25519 key).
///  - `joinerBlsPublicKey` — stable cross-device identifier used as
///    the dedup key in `ChatGroup.memberProfiles`. Optional for
///    backwards compat with builds that predate the directory; when
///    absent, the admin records the joiner under their inbox-pub
///    fallback (rendered as a generic peer with no cross-device
///    tracking).
///  - `joinerDisplayLabel` — UI hint for the inviter's "X wants to
///    join Y. Approve?" prompt. Joiner-controlled, **untrusted**;
///    the inviter's app should also surface
///    `joinerInboxPublicKey`'s hex prefix so the inviter can
///    verify out-of-band when the label can't be cross-checked.
///  - `groupId` — echoed back so the inviter's approval handler can
///    cross-check that the joiner is asking about the right group.
///  - `rulesHash` / `rulesSignature` — the joiner's agreement to the
///    group's rules, if the invitation carried any. See `GroupRules`
///    for the statement these cover and why the envelope's own
///    signature could not serve.
///
/// The OUTER envelope is the standard `SealedEnvelope` (X25519 +
/// AES-GCM sealed to the inviter's intro pubkey + Ed25519-signed
/// by the joiner's identity key). Reuses the existing seal/decrypt
/// machinery on `IdentityRepository`.
///
/// Wire-format-equivalent to onym-android's `JoinRequestPayload.kt`:
/// snake_case keys, base64 `Data` fields (Swift `JSONEncoder`'s
/// `.base64` default + Kotlin's `Base64.getEncoder()` produce the
/// same bytes).
public struct JoinRequestPayload: Codable, Equatable, Sendable {
    public let joinerInboxPublicKey: Data
    /// 48-byte arkworks-compressed BLS12-381 G1 pubkey. Optional —
    /// older joiner builds ship the request without it; the
    /// inviter's app records those joiners under an inbox-pub
    /// fallback key in `memberProfiles` rather than rejecting the
    /// request.
    public let joinerBlsPublicKey: Data?
    /// 32-byte Poseidon leaf hash — `Poseidon(joiner_bls_secret)`,
    /// computed by the joiner via `Common.leafHash(secretKey:)`.
    /// Required for the admin to extend the on-chain Merkle tree at
    /// approve time (`Tyranny.proveUpdate` needs it as part of the
    /// new packed leaf set).
    ///
    /// Optional on the wire — pre-PR-13 joiner builds shipped
    /// requests without it. Admins running a PR-13+ build MUST
    /// reject join requests missing this field for Tyranny groups,
    /// because the on-chain `update_commitment` proof can't be
    /// generated without it.
    public let joinerLeafHash: Data?
    /// 32-byte Ed25519 raw public key — joiner's
    /// `Identity.stellarPublicKey`. The admin reads this off the
    /// request and ships it back to existing members via
    /// `MemberAnnouncementPayload.AnnouncedMember.sendingPub` so they
    /// can verify the joiner's future chat-message envelope
    /// signatures (PR 4).
    public let joinerSendingPublicKey: Data
    public let joinerDisplayLabel: String
    public let groupId: Data
    /// 32-byte `SHA256` of the canonical rules text the joiner was
    /// shown. Absent when the invitation carried no rules, and when the
    /// joiner runs a build that predates them.
    ///
    /// Carried even though the inviter knows their own rules, because
    /// it is what distinguishes "agreed to an older version" from
    /// "signed nothing that verifies" — without it a stale agreement
    /// and a forged one look the same, and only one of them is worth
    /// asking the joiner to redo.
    public let rulesHash: Data?
    /// 64-byte Ed25519 signature over
    /// `GroupRules.statement(groupID:rulesHash:joinerSendingPublicKey:)`,
    /// made with the joiner's `joinerSendingPublicKey`. Verifiable by
    /// any member, since that key is announced to all of them.
    public let rulesSignature: Data?

    enum CodingKeys: String, CodingKey {
        case joinerInboxPublicKey = "joiner_inbox_pub"
        case joinerBlsPublicKey = "joiner_bls_pub"
        case joinerLeafHash = "joiner_leaf_hash"
        case joinerSendingPublicKey = "joiner_sending_pub"
        case joinerDisplayLabel = "joiner_display_label"
        case groupId = "group_id"
        case rulesHash = "rules_hash"
        case rulesSignature = "rules_signature"
    }

    public init(
        joinerInboxPublicKey: Data,
        joinerBlsPublicKey: Data?,
        joinerLeafHash: Data?,
        joinerSendingPublicKey: Data,
        joinerDisplayLabel: String,
        groupId: Data,
        rulesHash: Data? = nil,
        rulesSignature: Data? = nil
    ) throws {
        guard joinerInboxPublicKey.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "joinerInboxPublicKey: expected 32 bytes, got \(joinerInboxPublicKey.count)"
            )
        }
        if let bls = joinerBlsPublicKey, bls.count != 48 {
            throw JoinRequestPayloadError.shape(
                "joinerBlsPublicKey: expected 48 bytes, got \(bls.count)"
            )
        }
        if let leaf = joinerLeafHash, leaf.count != 32 {
            throw JoinRequestPayloadError.shape(
                "joinerLeafHash: expected 32 bytes, got \(leaf.count)"
            )
        }
        guard joinerSendingPublicKey.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "joinerSendingPublicKey: expected 32 bytes, got \(joinerSendingPublicKey.count)"
            )
        }
        guard groupId.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "groupId: expected 32 bytes, got \(groupId.count)"
            )
        }
        self.joinerInboxPublicKey = joinerInboxPublicKey
        self.joinerBlsPublicKey = joinerBlsPublicKey
        self.joinerLeafHash = joinerLeafHash
        self.joinerSendingPublicKey = joinerSendingPublicKey
        try Self.validateAgreement(hash: rulesHash, signature: rulesSignature)
        self.joinerDisplayLabel = joinerDisplayLabel
        self.groupId = groupId
        self.rulesHash = rulesHash
        self.rulesSignature = rulesSignature
    }

    /// Shape only — whether the signature *verifies* is
    /// `GroupRules.isAgreement`, which needs the rules text this type
    /// deliberately doesn't carry (the inviter has it; sending it back
    /// would let a joiner choose the text their own signature is
    /// checked against).
    private static func validateAgreement(hash: Data?, signature: Data?) throws {
        if let hash, hash.count != 32 {
            throw JoinRequestPayloadError.shape(
                "rulesHash: expected 32 bytes, got \(hash.count)"
            )
        }
        if let signature, signature.count != 64 {
            throw JoinRequestPayloadError.shape(
                "rulesSignature: expected 64 bytes, got \(signature.count)"
            )
        }
        // Half an agreement is not one. A signature with nothing naming
        // what it covers can't be checked, and a hash with no signature
        // is a claim rather than a proof — either alone would have to
        // be treated as "didn't sign", so say so at the boundary
        // instead of leaving every reader to remember it.
        if (hash == nil) != (signature == nil) {
            throw JoinRequestPayloadError.shape(
                "rulesHash and rulesSignature must be present together"
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pub = try c.decode(Data.self, forKey: .joinerInboxPublicKey)
        let bls = try c.decodeIfPresent(Data.self, forKey: .joinerBlsPublicKey)
        let leaf = try c.decodeIfPresent(Data.self, forKey: .joinerLeafHash)
        let sending = try c.decode(Data.self, forKey: .joinerSendingPublicKey)
        let label = try c.decode(String.self, forKey: .joinerDisplayLabel)
        let gid = try c.decode(Data.self, forKey: .groupId)
        guard pub.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "joinerInboxPublicKey: expected 32 bytes, got \(pub.count)"
            )
        }
        if let blsBytes = bls, blsBytes.count != 48 {
            throw JoinRequestPayloadError.shape(
                "joinerBlsPublicKey: expected 48 bytes, got \(blsBytes.count)"
            )
        }
        if let leafBytes = leaf, leafBytes.count != 32 {
            throw JoinRequestPayloadError.shape(
                "joinerLeafHash: expected 32 bytes, got \(leafBytes.count)"
            )
        }
        guard sending.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "joinerSendingPublicKey: expected 32 bytes, got \(sending.count)"
            )
        }
        guard gid.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "groupId: expected 32 bytes, got \(gid.count)"
            )
        }
        self.joinerInboxPublicKey = pub
        self.joinerBlsPublicKey = bls
        self.joinerLeafHash = leaf
        self.joinerSendingPublicKey = sending
        let rulesHash = try c.decodeIfPresent(Data.self, forKey: .rulesHash)
        let rulesSignature = try c.decodeIfPresent(Data.self, forKey: .rulesSignature)
        try Self.validateAgreement(hash: rulesHash, signature: rulesSignature)
        self.joinerDisplayLabel = label
        self.groupId = gid
        self.rulesHash = rulesHash
        self.rulesSignature = rulesSignature
    }
}

public enum JoinRequestPayloadError: Error, Equatable {
    case shape(String)
}
