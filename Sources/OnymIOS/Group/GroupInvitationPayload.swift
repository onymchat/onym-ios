import Foundation

/// Plaintext payload that gets sealed (X25519 + AES-GCM via
/// `IdentityRepository.sealInvitation`) and dropped on
/// `InboxTransport.send` for each invitee. Mirrors stellar-mls's
/// `InviteCode` shape so an Android / Apple receiver decoding the
/// payload sees the same fields.
///
/// Versioned for forward compatibility — `version = 1` is the only
/// shape the receiver has to handle today; later versions can add
/// fields with non-failing `decodeIfPresent` decoders.
struct GroupInvitationPayload: Codable, Equatable, Sendable {
    let version: Int
    let groupID: Data
    let groupSecret: Data
    let name: String
    /// Lex-sorted by `publicKeyCompressed` — the receiver MUST be
    /// able to recompute the same Poseidon root, which requires the
    /// same canonical order.
    let members: [GovernanceMember]
    let epoch: UInt64
    let salt: Data
    /// Latest verified Poseidon commitment. `nil` only for offline
    /// invitations not yet anchored on chain — current creator flow
    /// always anchors first, so this is always set in practice.
    let commitment: Data?
    let tierRaw: Int
    let groupTypeRaw: UInt32
    /// Lowercase hex (96 chars) BLS pubkey of the Tyranny admin.
    /// `nil` for `.anarchy` / `.oneOnOne`.
    let adminPubkeyHex: String?

    enum CodingKeys: String, CodingKey {
        case version
        case groupID = "group_id"
        case groupSecret = "group_secret"
        case name
        case members
        case epoch
        case salt
        case commitment
        case tierRaw = "tier_raw"
        case groupTypeRaw = "group_type_raw"
        case adminPubkeyHex = "admin_pubkey_hex"
    }
}
