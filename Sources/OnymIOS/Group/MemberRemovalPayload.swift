import Foundation

/// Plaintext payload the admin seals (via
/// `IdentityRepository.sealInvitation`, X25519 + AES-GCM, signed by
/// the admin's Ed25519 stellar key) and ships to every member's inbox
/// after removing a member from a Tyranny group. Tells receivers
/// "this person is no longer in the group — tombstone them and (for
/// remaining members) rotate to the fresh group secret".
///
/// ## Two audience variants of the same type
///
/// The admin encodes this payload twice per removal:
///
///  - **Remaining members** get the full variant: `groupSecretNew` +
///    `saltNew` carry the rotated secrets so their local group state
///    stays coherent (and any future key derivation from
///    `ChatGroup.groupSecret` excludes the removed member).
///  - **The removed member** gets the secret-free variant — both
///    optional fields omitted from the wire entirely (`encodeIfPresent`
///    drops the keys, not just the values). The victim learns *that*
///    they were removed, never the post-removal secrets. This mirrors
///    the `SEPRemovalNotice` / `SEPRekeyEnvelope` split from
///    stellar-mls collapsed into one type, safe here because every
///    payload is per-recipient sealed anyway.
///
/// ## Trust
///
/// Receivers MUST cross-check the outer `SealedEnvelope`'s verified
/// `senderEd25519PublicKey` against the group's stored
/// `adminEd25519PubkeyHex` (the dispatcher's
/// `isAuthorizedGroupMutation` gate) AND verify `commitment + epoch`
/// against the on-chain state before mutating local state. That logic
/// lives in the dispatcher — this type is a pure value carrier.
///
/// ## Wire disjointness
///
/// Every REQUIRED key is prefixed `removal_` so the dispatcher's
/// trial-decode chain can never confuse this payload with any of the
/// other inbox payloads in either direction (crucially:
/// `removal_group_id` not `group_id`, `group_secret_new` not
/// `group_secret`).
///
/// ## Versioning
///
/// `removal_version = 1` is the only shape receivers handle today.
/// Future fields land via non-failing `decodeIfPresent` decoders.
///
/// ## Cross-platform parity
///
/// Mirrors `MemberRemovalPayload.kt` from onym-android — the wire
/// format was authored there first; this file mirrors the snake_case
/// keys + base64 `Data` encoding (Swift `JSONEncoder`'s `.base64`
/// default + Kotlin's `Base64.getEncoder()` produce the same bytes).
struct MemberRemovalPayload: Codable, Equatable, Sendable {
    let version: Int
    /// 32-byte group ID — receivers cross-check against their local
    /// `ChatGroup.groupIDData` and drop removals for groups they
    /// don't know about.
    let groupID: Data
    /// Lowercase 96-char BLS pubkey hex of the removed member — the
    /// stable cross-device identifier, and the dedup key into
    /// `ChatGroup.memberProfiles`. A receiver whose own BLS key
    /// matches is the removal target.
    let removedBlsHex: String
    /// 32-byte Poseidon commitment of the post-removal tree, as
    /// anchored on chain by the admin's `update_commitment`.
    let commitment: Data
    /// Post-removal epoch (`epoch_old + 1`). Verified against the
    /// on-chain entry with the same converge-forward gate as member
    /// announcements.
    let epoch: UInt64
    /// Admin's wall clock at send time (informational — receivers
    /// order by arrival, and idempotency keys off epoch).
    let sentAtMillis: Int64
    /// Rotated 32-byte group secret. Remaining-members variant only —
    /// NEVER present on the copy sealed to the removed member.
    let groupSecretNew: Data?
    /// Rotated 32-byte salt matching the post-removal commitment.
    /// Remaining-members variant only, like `groupSecretNew`.
    let saltNew: Data?

    enum CodingKeys: String, CodingKey {
        case version = "removal_version"
        case groupID = "removal_group_id"
        case removedBlsHex = "removal_member_bls_hex"
        case commitment = "removal_commitment"
        case epoch = "removal_epoch"
        case sentAtMillis = "removal_sent_at_millis"
        case groupSecretNew = "group_secret_new"
        case saltNew = "salt_new"
    }

    init(
        version: Int,
        groupID: Data,
        removedBlsHex: String,
        commitment: Data,
        epoch: UInt64,
        sentAtMillis: Int64,
        groupSecretNew: Data? = nil,
        saltNew: Data? = nil
    ) throws {
        try Self.validate(
            groupID: groupID,
            removedBlsHex: removedBlsHex,
            commitment: commitment,
            groupSecretNew: groupSecretNew,
            saltNew: saltNew
        )
        self.version = version
        self.groupID = groupID
        self.removedBlsHex = removedBlsHex
        self.commitment = commitment
        self.epoch = epoch
        self.sentAtMillis = sentAtMillis
        self.groupSecretNew = groupSecretNew
        self.saltNew = saltNew
    }

    /// The wire-side decode boundary — validate sizes at decode like
    /// `MemberProfile` / `MemberAnnouncementPayload` so a wrong-sized
    /// key can never become local group state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        let groupID = try c.decode(Data.self, forKey: .groupID)
        let removedBlsHex = try c.decode(String.self, forKey: .removedBlsHex)
        let commitment = try c.decode(Data.self, forKey: .commitment)
        let epoch = try c.decode(UInt64.self, forKey: .epoch)
        let sentAtMillis = try c.decode(Int64.self, forKey: .sentAtMillis)
        let groupSecretNew = try c.decodeIfPresent(Data.self, forKey: .groupSecretNew)
        let saltNew = try c.decodeIfPresent(Data.self, forKey: .saltNew)
        try Self.validate(
            groupID: groupID,
            removedBlsHex: removedBlsHex,
            commitment: commitment,
            groupSecretNew: groupSecretNew,
            saltNew: saltNew
        )
        self.version = version
        self.groupID = groupID
        self.removedBlsHex = removedBlsHex
        self.commitment = commitment
        self.epoch = epoch
        self.sentAtMillis = sentAtMillis
        self.groupSecretNew = groupSecretNew
        self.saltNew = saltNew
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(groupID, forKey: .groupID)
        try c.encode(removedBlsHex, forKey: .removedBlsHex)
        try c.encode(commitment, forKey: .commitment)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(sentAtMillis, forKey: .sentAtMillis)
        // The victim's copy must omit the keys ENTIRELY (not encode
        // them as null) — `encodeIfPresent` matches Android's
        // `encodeDefaults = false` posture.
        try c.encodeIfPresent(groupSecretNew, forKey: .groupSecretNew)
        try c.encodeIfPresent(saltNew, forKey: .saltNew)
    }

    private static func validate(
        groupID: Data,
        removedBlsHex: String,
        commitment: Data,
        groupSecretNew: Data?,
        saltNew: Data?
    ) throws {
        guard groupID.count == 32 else {
            throw MemberRemovalPayloadError.shape(
                "groupID: expected 32 bytes, got \(groupID.count)"
            )
        }
        guard removedBlsHex.count == 96 else {
            throw MemberRemovalPayloadError.shape(
                "removedBlsHex: expected 96 hex chars, got \(removedBlsHex.count)"
            )
        }
        guard commitment.count == 32 else {
            throw MemberRemovalPayloadError.shape(
                "commitment: expected 32 bytes, got \(commitment.count)"
            )
        }
        if let secret = groupSecretNew, secret.count != 32 {
            throw MemberRemovalPayloadError.shape(
                "groupSecretNew: expected 32 bytes, got \(secret.count)"
            )
        }
        if let salt = saltNew, salt.count != 32 {
            throw MemberRemovalPayloadError.shape(
                "saltNew: expected 32 bytes, got \(salt.count)"
            )
        }
    }
}

enum MemberRemovalPayloadError: Error, Equatable {
    case shape(String)
}
