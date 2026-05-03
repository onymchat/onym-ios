import Foundation

/// Inner plaintext of the sealed envelope a joiner sends to an
/// inviter's intro inbox. Carries everything the inviter's app
/// needs to ship the actual sealed `GroupInvitationPayload` back:
///
///  - `joinerInboxPublicKey` — where the sealed invitation will be
///    posted (the joiner's identity inbox X25519 key).
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
    let joinerDisplayLabel: String
    let groupId: Data

    enum CodingKeys: String, CodingKey {
        case joinerInboxPublicKey = "joiner_inbox_pub"
        case joinerDisplayLabel = "joiner_display_label"
        case groupId = "group_id"
    }

    init(
        joinerInboxPublicKey: Data,
        joinerDisplayLabel: String,
        groupId: Data
    ) throws {
        guard joinerInboxPublicKey.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "joinerInboxPublicKey: expected 32 bytes, got \(joinerInboxPublicKey.count)"
            )
        }
        guard groupId.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "groupId: expected 32 bytes, got \(groupId.count)"
            )
        }
        self.joinerInboxPublicKey = joinerInboxPublicKey
        self.joinerDisplayLabel = joinerDisplayLabel
        self.groupId = groupId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pub = try c.decode(Data.self, forKey: .joinerInboxPublicKey)
        let label = try c.decode(String.self, forKey: .joinerDisplayLabel)
        let gid = try c.decode(Data.self, forKey: .groupId)
        guard pub.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "joinerInboxPublicKey: expected 32 bytes, got \(pub.count)"
            )
        }
        guard gid.count == 32 else {
            throw JoinRequestPayloadError.shape(
                "groupId: expected 32 bytes, got \(gid.count)"
            )
        }
        self.joinerInboxPublicKey = pub
        self.joinerDisplayLabel = label
        self.groupId = gid
    }
}

enum JoinRequestPayloadError: Error, Equatable {
    case shape(String)
}
