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
struct JoinRequestPayload: Codable, Equatable, Sendable {
    let joinerInboxPublicKey: Data
    /// 48-byte arkworks-compressed BLS12-381 G1 pubkey. Optional —
    /// older joiner builds ship the request without it; the
    /// inviter's app records those joiners under an inbox-pub
    /// fallback key in `memberProfiles` rather than rejecting the
    /// request.
    let joinerBlsPublicKey: Data?
    let joinerDisplayLabel: String
    let groupId: Data

    enum CodingKeys: String, CodingKey {
        case joinerInboxPublicKey = "joiner_inbox_pub"
        case joinerBlsPublicKey = "joiner_bls_pub"
        case joinerDisplayLabel = "joiner_display_label"
        case groupId = "group_id"
    }

    init(
        joinerInboxPublicKey: Data,
        joinerBlsPublicKey: Data?,
        joinerDisplayLabel: String,
        groupId: Data
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
        guard groupId.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "groupId: expected 32 bytes, got \(groupId.count)"
            )
        }
        self.joinerInboxPublicKey = joinerInboxPublicKey
        self.joinerBlsPublicKey = joinerBlsPublicKey
        self.joinerDisplayLabel = joinerDisplayLabel
        self.groupId = groupId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pub = try c.decode(Data.self, forKey: .joinerInboxPublicKey)
        let bls = try c.decodeIfPresent(Data.self, forKey: .joinerBlsPublicKey)
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
        guard gid.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "groupId: expected 32 bytes, got \(gid.count)"
            )
        }
        self.joinerInboxPublicKey = pub
        self.joinerBlsPublicKey = bls
        self.joinerDisplayLabel = label
        self.groupId = gid
    }
}

enum JoinRequestPayloadError: Error, Equatable {
    case shape(String)
}
