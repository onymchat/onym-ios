import Foundation

/// Dedicated "group name" control message: the admin broadcasting a
/// renamed group to every member, out of band from the chat timeline.
/// Sealed (X25519 + AES-GCM via `IdentityRepository.sealInvitation`) and
/// shipped on the same per-inbox envelope path as `GroupAvatarPayload` —
/// one envelope per member inbox.
///
/// Reaches members who weren't present when the name was set into the
/// invitation snapshot (late joiners) and carries every later rename.
///
/// The `name_*` wire keys are deliberately distinct (mirroring
/// `GroupAvatarPayload`'s `avatar_*`) so the dispatcher's structural JSON
/// decode can't confuse this with any other payload — the required,
/// uniquely-prefixed keys keep the trial-decode unambiguous.
///
/// This message always expresses the *current* name, so the receiver
/// overwrites its local group name with `name` (after the admin gate).
/// The name is app metadata only — it never touches on-chain state.
struct GroupNamePayload: Codable, Equatable, Sendable {
    /// Wire schema version. `1` is the only shape today.
    let version: Int
    /// 32-byte group ID. Receiver looks up the local `ChatGroup` by it
    /// and drops the message if no such group exists.
    let groupID: Data
    /// Lowercase BLS pubkey hex (96 chars) of the admin who set it.
    /// Informational — receiver authenticates via the envelope's
    /// Ed25519 signer against the group's stored admin key, not this.
    let senderBlsPubkeyHex: String
    /// Milliseconds since Unix epoch at send time. Int64 for an
    /// unambiguous cross-platform wire format.
    let sentAtMillis: Int64
    /// The new group name. Untrusted text — render, don't trust.
    let name: String

    enum CodingKeys: String, CodingKey {
        case version = "name_version"
        case groupID = "name_group_id"
        case senderBlsPubkeyHex = "name_sender_bls_hex"
        case sentAtMillis = "name_sent_at_millis"
        case name = "name_value"
    }
}
