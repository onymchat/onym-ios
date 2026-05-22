import Foundation

/// Member → admin "send me the current group state" request, sealed to
/// the admin's inbox and signed by the requester's Ed25519.
///
/// ## Why this exists
///
/// A Tyranny invitation is a snapshot pinned to one epoch. The receiver
/// verifies it by recomputing `Poseidon(Poseidon(merkleRoot(members),
/// epoch), salt)` and matching the on-chain commitment — but the chain
/// only stores the *latest* `(commitment, epoch)`. If another invitee
/// was anchored between the snapshot being sealed and it landing, the
/// snapshot is from a past epoch the chain no longer holds, so it can't
/// be verified (and we refuse to materialize an unverifiable group —
/// see `GroupStateVerifier`).
///
/// To recover, the receiver asks the admin for the *current* state. The
/// admin replies with a fresh `GroupInvitationPayload` at the current
/// `(epoch, salt, members, commitment)`, which the receiver verifies at
/// an exact epoch match. This is the "verify at current state" leg of
/// the converge-forward design.
///
/// ## Privacy
///
/// The reply carries `salt` (the on-chain roster-privacy blinding
/// factor), so the admin MUST only answer requesters that are in the
/// *current* roster — `GroupStateVerifier.handleRefreshRequest` gates on
/// membership + an Ed25519-signer check before replying. The request
/// itself reveals only that the requester wants to resync a group it was
/// invited to.
///
/// ## Wire disambiguation
///
/// `refresh_group_id` + `requester_inbox_pub` are required and unique to
/// this type; no other inbox payload decodes as one.
struct GroupStateRefreshRequest: Codable, Equatable, Sendable {
    let version: Int
    /// 32-byte on-chain `group_id` the requester wants the current
    /// state for.
    let groupID: Data
    /// Requester's 32-byte X25519 inbox key — where the admin seals the
    /// fresh snapshot reply.
    let requesterInboxPublicKey: Data
    /// Requester's 48-byte compressed BLS pubkey — used by the admin to
    /// confirm the requester is in the current roster before disclosing
    /// the salt.
    let requesterBlsPublicKey: Data

    enum CodingKeys: String, CodingKey {
        case version = "refresh_version"
        case groupID = "refresh_group_id"
        case requesterInboxPublicKey = "requester_inbox_pub"
        case requesterBlsPublicKey = "requester_bls_pub"
    }

    init(
        version: Int = 1,
        groupID: Data,
        requesterInboxPublicKey: Data,
        requesterBlsPublicKey: Data
    ) throws {
        guard groupID.count == 32 else {
            throw GroupStateRefreshRequestError.shape(
                "groupID: expected 32 bytes, got \(groupID.count)"
            )
        }
        guard requesterInboxPublicKey.count == 32 else {
            throw GroupStateRefreshRequestError.shape(
                "requesterInboxPublicKey: expected 32 bytes, got \(requesterInboxPublicKey.count)"
            )
        }
        guard requesterBlsPublicKey.count == 48 else {
            throw GroupStateRefreshRequestError.shape(
                "requesterBlsPublicKey: expected 48 bytes, got \(requesterBlsPublicKey.count)"
            )
        }
        self.version = version
        self.groupID = groupID
        self.requesterInboxPublicKey = requesterInboxPublicKey
        self.requesterBlsPublicKey = requesterBlsPublicKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: c.decode(Int.self, forKey: .version),
            groupID: c.decode(Data.self, forKey: .groupID),
            requesterInboxPublicKey: c.decode(Data.self, forKey: .requesterInboxPublicKey),
            requesterBlsPublicKey: c.decode(Data.self, forKey: .requesterBlsPublicKey)
        )
    }
}

enum GroupStateRefreshRequestError: Error, Equatable {
    case shape(String)
}
