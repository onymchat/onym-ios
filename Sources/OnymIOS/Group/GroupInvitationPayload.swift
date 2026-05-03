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
    /// Lowercase governance type label — `tyranny`, `anarchy`, etc.
    /// Receiver decodes via `SEPGroupType(rawValue:)`. String spelling
    /// matches the relayer + contract wire format so a single
    /// `group_type` field is unambiguous across iOS, Android, and the
    /// Stellar contract.
    let groupTypeRaw: String
    /// Lowercase hex (96 chars) BLS pubkey of the Tyranny admin.
    /// `nil` for `.anarchy` / `.oneOnOne`.
    let adminPubkeyHex: String?
    /// 32-byte BLS Fr scalar minted by the creator for the peer party
    /// in a 1-on-1 dialog. The receiver MUST adopt this as their
    /// per-dialog BLS identity — the founding proof was generated with
    /// both parties' secrets, so there is no other key the receiver
    /// could use to derive the same per-epoch keys. `nil` for every
    /// other governance type.
    ///
    /// Decoded via `decodeIfPresent` so older invitations (and other
    /// group types that never set this field) round-trip cleanly.
    let peerBlsSecret: Data?

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
        case peerBlsSecret = "peer_bls_secret"
    }

    init(
        version: Int,
        groupID: Data,
        groupSecret: Data,
        name: String,
        members: [GovernanceMember],
        epoch: UInt64,
        salt: Data,
        commitment: Data?,
        tierRaw: Int,
        groupTypeRaw: String,
        adminPubkeyHex: String?,
        peerBlsSecret: Data? = nil
    ) {
        self.version = version
        self.groupID = groupID
        self.groupSecret = groupSecret
        self.name = name
        self.members = members
        self.epoch = epoch
        self.salt = salt
        self.commitment = commitment
        self.tierRaw = tierRaw
        self.groupTypeRaw = groupTypeRaw
        self.adminPubkeyHex = adminPubkeyHex
        self.peerBlsSecret = peerBlsSecret
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        groupID = try c.decode(Data.self, forKey: .groupID)
        groupSecret = try c.decode(Data.self, forKey: .groupSecret)
        name = try c.decode(String.self, forKey: .name)
        members = try c.decode([GovernanceMember].self, forKey: .members)
        epoch = try c.decode(UInt64.self, forKey: .epoch)
        salt = try c.decode(Data.self, forKey: .salt)
        commitment = try c.decodeIfPresent(Data.self, forKey: .commitment)
        tierRaw = try c.decode(Int.self, forKey: .tierRaw)
        groupTypeRaw = try c.decode(String.self, forKey: .groupTypeRaw)
        adminPubkeyHex = try c.decodeIfPresent(String.self, forKey: .adminPubkeyHex)
        peerBlsSecret = try c.decodeIfPresent(Data.self, forKey: .peerBlsSecret)
    }
}
