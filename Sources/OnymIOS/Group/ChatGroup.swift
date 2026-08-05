import Foundation

/// In-memory snapshot of a chat group as the iOS app understands it.
/// PR-A holds this purely as a value type — `GroupRepository` and the
/// SwiftData @Model land in PR-B.
///
/// Trimmed compared to `stellar-mls/clients/ios/StellarChat/Models/ChatGroup`:
/// the chat-message / avatar / push fields are out of scope until the
/// chat screen ships. `groupSecret` stays in the type because it's
/// seeded into the invitation envelope at create time and the receiver
/// needs it to derive message-keys later.
struct ChatGroup: Identifiable, Equatable, Sendable {
    /// Hex-encoded 32-byte group ID.
    let id: String
    /// The identity that created this group. Stamped at create time
    /// from the currently-selected identity; the chats list filters
    /// by it so switching identities hides the other one's groups.
    /// Removing an identity wipes every group with a matching owner.
    let ownerIdentityID: IdentityID
    /// Mutable so the admin can rename the group post-creation
    /// (`GroupAvatarBroadcaster.setName` + `GroupNamePayload`). Persisted
    /// via `PersistedGroup.encryptedName`.
    var name: String
    /// 32-byte shared secret. Used for `topicTag` derivation and message
    /// key HKDF — both still TBD on iOS, but the value must be sealed
    /// into the invitation now so receivers can rebuild the same key.
    /// Mutable because a member removal rotates it: the admin mints a
    /// fresh secret and remaining members swap to it via
    /// `MemberRemovalPayload.groupSecretNew`.
    var groupSecret: Data
    let createdAt: Date

    var members: [GovernanceMember]
    /// View-facing directory of people the local user has interacted
    /// with through this group, keyed by lowercase BLS pubkey hex.
    /// Populated for the creator at group-create time and extended as
    /// joiners are admitted (post-PR fanout).
    ///
    /// Independent of `members`: that's the on-chain Merkle-tree
    /// roster, advanced by the admin's `update_commitment` on every
    /// join / removal. `memberProfiles` is the app-level "who am I
    /// talking to" directory (aliases, inbox keys, tombstones). The
    /// two usually agree but may briefly diverge while a roster
    /// mutation propagates.
    var memberProfiles: [String: MemberProfile]
    var epoch: UInt64
    var salt: Data
    /// Latest verified Poseidon commitment. `nil` until the first
    /// `recomputeCommitment` call (or until on-chain state is read back).
    var commitment: Data?
    var tier: SEPTier
    var groupType: SEPGroupType
    /// Hex (lowercase, 96 chars) BLS pubkey of the single Tyranny admin.
    /// `nil` for `.anarchy` / `.oneOnOne` (no privileged member).
    var adminPubkeyHex: String?
    /// Hex (lowercase, 64 chars) Ed25519 pubkey of the admin —
    /// HKDF-derived from their nostr secret on the admin's device.
    /// Captured at materialize time from the inviting envelope's
    /// `senderEd25519PublicKey`, or stamped at create time from the
    /// creator's own `Identity.stellarPublicKey`. Used by the
    /// receive-side dispatcher to verify that an inbound
    /// `MemberAnnouncementPayload` was actually signed by the
    /// known admin (and not a peer who happens to know the
    /// recipient's inbox pubkey).
    ///
    /// `nil` for `.anarchy` / `.oneOnOne` (no admin) or when a
    /// pre-PR-9 group was materialized before the field existed —
    /// announcements for such groups fall back to V1 best-effort
    /// (decrypt-only verification).
    var adminEd25519PubkeyHex: String?
    /// Flips to `true` once the relayer's `create_group_v2` returns
    /// `accepted = true`. Persisted-but-not-anchored groups can be
    /// retried.
    var isPublishedOnChain: Bool
    /// Square JPEG (256×256, ≤16 KB — see `GroupAvatarImage`) the user
    /// or admin set as the group photo. `nil` falls back to the Onym
    /// brand mark in `OnymGroupAvatar`. Travels in the invitation
    /// snapshot at create time and via `GroupAvatarPayload` afterwards.
    /// Defaulted so existing construction sites need no change.
    var avatarJPEG: Data? = nil

    /// When the local user last opened / read this thread. Drives the
    /// chat-list unread badge (incoming messages with `sentAt > lastReadAt`
    /// are unread). `nil` = never opened (everything counts as unread).
    /// Defaulted so existing construction sites need no change.
    var lastReadAt: Date? = nil

    /// Optional free-text invitation the creator wrote — a greeting,
    /// group policy, or articles of association. Set at create time,
    /// sealed into the invite payloads so joiners read it before
    /// accepting, and persisted here as the group's intro. `nil` = none.
    /// Defaulted so existing construction sites need no change.
    var invitationMessage: String? = nil

    /// `true` once this device's owner has been removed from the group
    /// by the admin (a self-targeting `MemberRemovalPayload` landed).
    /// The thread stays readable but the composer is replaced by a
    /// "you were removed" banner and `SendMessageInteractor` refuses
    /// sends. Local-only — never on the wire; defaulted so existing
    /// construction sites need no change. Mirrors
    /// `ChatGroup.membershipRevoked` from onym-android.
    var membershipRevoked: Bool = false

    /// `memberProfiles` minus tombstoned (removed) members — what the
    /// UI means by "the members": counts, rosters, alias enumerations.
    /// Message-rendering alias lookups keep using the full map so a
    /// removed member's past messages still show their name.
    var activeMemberProfiles: [String: MemberProfile] {
        memberProfiles.filter { !$0.value.revoked }
    }

    /// Group ID as the raw 32-byte payload (parsed back from `id`).
    /// Used directly when building chain payloads + invitations.
    var groupIDData: Data {
        ChatGroup.bytes(fromHex: id)
    }

    static func bytes(fromHex hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }
        return data
    }
}
