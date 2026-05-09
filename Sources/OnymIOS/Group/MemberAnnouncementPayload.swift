import Foundation

/// Plaintext payload that the admin seals (via
/// `IdentityRepository.sealInvitation`, X25519 + AES-GCM, signed by
/// the admin's Ed25519 stellar key) and ships to every existing
/// member's inbox after they Approve a join request. Tells receivers
/// "this person just joined the group — append them to your local
/// roster".
///
/// Sits alongside `GroupInvitationPayload`:
///   - `GroupInvitationPayload` is the joiner's first taste of a
///     group — full state needed to render messages.
///   - `MemberAnnouncementPayload` is incremental — existing
///     members already know the group, they just need to learn
///     about one new entry in the roster.
///
/// ## Trust
///
/// `newMember.alias` and `adminAlias` are self-asserted. Receivers
/// that care about provenance should display the BLS-pubkey
/// fingerprint alongside (matches the inviter-approval guidance on
/// `JoinRequestPayload`). The OUTER `SealedEnvelope` carries the
/// admin's Ed25519 signature over the ephemeral key — receivers
/// MUST cross-check `senderEd25519PublicKey` against the group's
/// stored `adminPubkeyHex` (or, for governance models without an
/// admin, against the existing-member set) before mutating local
/// state. That signature check lives in the dispatcher (PR 5),
/// not here — this type is a pure value carrier.
///
/// ## Versioning
///
/// `version = 1` is the only shape receivers handle today. Future
/// fields land via non-failing `decodeIfPresent` decoders so older
/// builds round-trip unknown announcements as best-effort.
///
/// ## Cross-platform parity
///
/// Wire format authored on iOS first; onym-android mirrors the
/// snake_case keys + base64 `Data` encoding (Swift `JSONEncoder`'s
/// `.base64` default + Kotlin's `Base64.getEncoder()` produce the
/// same bytes).
struct MemberAnnouncementPayload: Codable, Equatable, Sendable {
    let version: Int
    /// 32-byte group ID — receivers cross-check against their
    /// local `ChatGroup.groupIDData` to refuse announcements for
    /// groups they don't know about.
    let groupId: Data
    let newMember: AnnouncedMember
    /// Admin's user-visible alias at send time. Carried alongside
    /// the announcement so the receiver can render "Y admitted X"
    /// without needing a prior alias map keyed by admin pubkey
    /// (which the receiver does have, but rendering becomes
    /// strictly local-state-free this way).
    let adminAlias: String
    /// 32-byte Poseidon commitment of the new tree (post-admit).
    /// PR-13a (admin side): admin runs `update_commitment` BEFORE
    /// fanning out the announcement and stamps the new commitment
    /// here. PR-13b (receiver side): the dispatcher fetches the
    /// on-chain commitment via `SEPContractClient.getCommitment(...)`
    /// and rejects announcements where these don't match.
    ///
    /// Optional on the wire — pre-PR-13 senders shipped
    /// announcements without this field. Receivers running PR-13b+
    /// MUST reject Tyranny announcements missing this field
    /// (best-effort acceptance is no longer safe once the trust
    /// model upgrades to on-chain anchoring).
    let commitment: Data?
    /// New epoch number after the on-chain `update_commitment`
    /// (i.e. `epoch_old + 1`). Optional for the same reason as
    /// `commitment`.
    let epoch: UInt64?

    /// One member's directory entry. App-level only — the
    /// cryptographic Poseidon leaf hash is intentionally absent.
    /// V1 group rosters are static on-chain (the joiner is not yet a
    /// member of the Merkle tree; `update_commitment` is post-V1
    /// scope in the SEP contracts), so the leaf hash is meaningless
    /// to ship today. When on-chain joiner ceremonies land, a
    /// `leaf_hash` field can return via a non-failing
    /// `decodeIfPresent` decoder without breaking older receivers.
    ///
    /// `blsPub` is still carried as the **stable cross-device
    /// identifier**: it's HKDF-derived from the joiner's identity
    /// secret, so the same pubkey persists across recovery-phrase
    /// restores and forms the dedup key in
    /// `ChatGroup.memberProfiles`.
    struct AnnouncedMember: Codable, Equatable, Sendable {
        /// 48-byte arkworks-compressed BLS12-381 G1 pubkey.
        let blsPub: Data
        /// 32-byte X25519 raw inbox public key.
        let inboxPub: Data
        /// Self-asserted display alias.
        let alias: String

        enum CodingKeys: String, CodingKey {
            case blsPub = "bls_pub"
            case inboxPub = "inbox_pub"
            case alias
        }

        init(blsPub: Data, inboxPub: Data, alias: String) throws {
            try Self.validate(blsPub: blsPub, inboxPub: inboxPub)
            self.blsPub = blsPub
            self.inboxPub = inboxPub
            self.alias = alias
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let bls = try c.decode(Data.self, forKey: .blsPub)
            let inbox = try c.decode(Data.self, forKey: .inboxPub)
            let alias = try c.decode(String.self, forKey: .alias)
            try Self.validate(blsPub: bls, inboxPub: inbox)
            self.blsPub = bls
            self.inboxPub = inbox
            self.alias = alias
        }

        private static func validate(blsPub: Data, inboxPub: Data) throws {
            guard blsPub.count == 48 else {
                throw MemberAnnouncementPayloadError.shape(
                    "blsPub: expected 48 bytes, got \(blsPub.count)"
                )
            }
            guard inboxPub.count == 32 else {
                throw MemberAnnouncementPayloadError.shape(
                    "inboxPub: expected 32 bytes, got \(inboxPub.count)"
                )
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case groupId = "group_id"
        case newMember = "new_member"
        case adminAlias = "admin_alias"
        case commitment
        case epoch
    }

    init(
        version: Int,
        groupId: Data,
        newMember: AnnouncedMember,
        adminAlias: String,
        commitment: Data? = nil,
        epoch: UInt64? = nil
    ) throws {
        guard groupId.count == 32 else {
            throw MemberAnnouncementPayloadError.shape(
                "groupId: expected 32 bytes, got \(groupId.count)"
            )
        }
        if let c = commitment, c.count != 32 {
            throw MemberAnnouncementPayloadError.shape(
                "commitment: expected 32 bytes, got \(c.count)"
            )
        }
        self.version = version
        self.groupId = groupId
        self.newMember = newMember
        self.adminAlias = adminAlias
        self.commitment = commitment
        self.epoch = epoch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        let gid = try c.decode(Data.self, forKey: .groupId)
        guard gid.count == 32 else {
            throw MemberAnnouncementPayloadError.shape(
                "groupId: expected 32 bytes, got \(gid.count)"
            )
        }
        let commitment = try c.decodeIfPresent(Data.self, forKey: .commitment)
        if let comm = commitment, comm.count != 32 {
            throw MemberAnnouncementPayloadError.shape(
                "commitment: expected 32 bytes, got \(comm.count)"
            )
        }
        self.version = v
        self.groupId = gid
        self.newMember = try c.decode(AnnouncedMember.self, forKey: .newMember)
        self.adminAlias = try c.decode(String.self, forKey: .adminAlias)
        self.commitment = commitment
        self.epoch = try c.decodeIfPresent(UInt64.self, forKey: .epoch)
    }
}

enum MemberAnnouncementPayloadError: Error, Equatable {
    case shape(String)
}
