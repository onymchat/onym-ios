import Foundation

/// Dedicated "avatar" control message: the admin broadcasting the group
/// photo to every member, out of band from the chat timeline. Sealed
/// (X25519 + AES-GCM via `IdentityRepository.sealInvitation`) and
/// shipped on the same per-inbox envelope path as
/// `MemberAnnouncementPayload` — one envelope per member inbox.
///
/// Reaches members who weren't present when the photo was set into the
/// invitation snapshot (late joiners) and carries every later change.
///
/// The `avatar_*` wire keys are deliberately distinct (mirroring
/// `GroupStateRefreshRequest`'s `refresh_*`) so the dispatcher's
/// structural JSON decode can't confuse this with a `ChatMessagePayload`
/// — the two otherwise share `version` / `group_id` / sender / timestamp.
///
/// This message always expresses the *current* avatar state, so a `nil`
/// / absent `avatar` means the photo was removed, not "unspecified".
struct GroupAvatarPayload: Codable, Equatable, Sendable {
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
    /// Square JPEG (256×256, ≤16 KB — see `GroupAvatarImage`), base64 on
    /// the wire via `Data`'s default Codable. `nil` = photo removed.
    let avatar: Data?

    enum CodingKeys: String, CodingKey {
        case version = "avatar_version"
        case groupID = "avatar_group_id"
        case senderBlsPubkeyHex = "avatar_sender_bls_hex"
        case sentAtMillis = "avatar_sent_at_millis"
        case avatar
    }
}
