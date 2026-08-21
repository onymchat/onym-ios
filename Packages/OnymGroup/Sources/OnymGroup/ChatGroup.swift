import Foundation
import OnymChain
import OnymIdentity

/// In-memory snapshot of a chat group as the iOS app understands it.
/// PR-A holds this purely as a value type — `GroupRepository` and the
/// SwiftData @Model land in PR-B.
///
/// Trimmed compared to `stellar-mls/clients/ios/StellarChat/Models/ChatGroup`:
/// the chat-message / avatar / push fields are out of scope until the
/// chat screen ships. `groupSecret` stays in the type because it's
/// seeded into the invitation envelope at create time and the receiver
/// needs it to derive message-keys later.
public struct ChatGroup: Identifiable, Equatable, Sendable {
    /// Hex-encoded 32-byte group ID.
    public let id: String
    /// The identity that created this group. Stamped at create time
    /// from the currently-selected identity; the chats list filters
    /// by it so switching identities hides the other one's groups.
    /// Removing an identity wipes every group with a matching owner.
    public let ownerIdentityID: IdentityID
    /// Mutable so the admin can rename the group post-creation
    /// (`GroupAvatarBroadcaster.setName` + `GroupNamePayload`). Persisted
    /// via `PersistedGroup.encryptedName`.
    public var name: String
    /// 32-byte shared secret. Used for `topicTag` derivation and message
    /// key HKDF — both still TBD on iOS, but the value must be sealed
    /// into the invitation now so receivers can rebuild the same key.
    public let groupSecret: Data
    public let createdAt: Date

    public var members: [GovernanceMember]
    /// View-facing directory of people the local user has interacted
    /// with through this group, keyed by lowercase BLS pubkey hex.
    /// Populated for the creator at group-create time and extended as
    /// joiners are admitted (post-PR fanout).
    ///
    /// Independent of `members`: V1 group rosters are static
    /// on-chain (`update_commitment` is post-V1 in the SEP
    /// contracts), so a joiner is "in the group" at the app level —
    /// receiving messages, listed in the chat detail — without yet
    /// being a `GovernanceMember` in the cryptographic Merkle tree.
    /// `members` is the on-chain truth; `memberProfiles` is the
    /// app-level "who am I talking to" directory. They may diverge.
    public var memberProfiles: [String: MemberProfile]
    public var epoch: UInt64
    public var salt: Data
    /// Latest verified Poseidon commitment. `nil` until the first
    /// `recomputeCommitment` call (or until on-chain state is read back).
    public var commitment: Data?
    public var tier: SEPTier
    public var groupType: SEPGroupType
    /// Hex (lowercase, 96 chars) BLS pubkey of the single Tyranny admin.
    /// `nil` for `.anarchy` / `.oneOnOne` (no privileged member).
    public var adminPubkeyHex: String?
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
    public var adminEd25519PubkeyHex: String?
    /// Flips to `true` once the relayer's `create_group_v2` returns
    /// `accepted = true`. Persisted-but-not-anchored groups can be
    /// retried.
    public var isPublishedOnChain: Bool
    /// Square JPEG (256×256, ≤16 KB — see `GroupAvatarImage`) the user
    /// or admin set as the group photo. `nil` falls back to the Onym
    /// brand mark in `OnymGroupAvatar`. Travels in the invitation
    /// snapshot at create time and via `GroupAvatarPayload` afterwards.
    /// Defaulted so existing construction sites need no change.
    public var avatarJPEG: Data? = nil

    /// When the local user last opened / read this thread. Drives the
    /// chat-list unread badge (incoming messages with `sentAt > lastReadAt`
    /// are unread). `nil` = never opened (everything counts as unread).
    /// Defaulted so existing construction sites need no change.
    public var lastReadAt: Date? = nil

    /// Optional free-text invitation the creator wrote — a greeting,
    /// group policy, or articles of association. Set at create time,
    /// sealed into the invite payloads so joiners read it before
    /// accepting, and persisted here as the group's intro. `nil` = none.
    /// Defaulted so existing construction sites need no change.
    public var invitationMessage: String? = nil

    public init(
        id: String,
        ownerIdentityID: IdentityID,
        name: String,
        groupSecret: Data,
        createdAt: Date,
        members: [GovernanceMember],
        memberProfiles: [String: MemberProfile],
        epoch: UInt64,
        salt: Data,
        commitment: Data?,
        tier: SEPTier,
        groupType: SEPGroupType,
        adminPubkeyHex: String?,
        adminEd25519PubkeyHex: String?,
        isPublishedOnChain: Bool,
        avatarJPEG: Data? = nil,
        lastReadAt: Date? = nil,
        invitationMessage: String? = nil
    ) {
        self.id = id
        self.ownerIdentityID = ownerIdentityID
        self.name = name
        self.groupSecret = groupSecret
        self.createdAt = createdAt
        self.members = members
        self.memberProfiles = memberProfiles
        self.epoch = epoch
        self.salt = salt
        self.commitment = commitment
        self.tier = tier
        self.groupType = groupType
        self.adminPubkeyHex = adminPubkeyHex
        self.adminEd25519PubkeyHex = adminEd25519PubkeyHex
        self.isPublishedOnChain = isPublishedOnChain
        self.avatarJPEG = avatarJPEG
        self.lastReadAt = lastReadAt
        self.invitationMessage = invitationMessage
    }

    /// The group's rules if a link can carry them, else nil.
    ///
    /// Groups created before the cap existed can hold a message longer
    /// than an invite link accepts — the field was documented as "any
    /// length" — and `IntroCapability` rejects those, which turned
    /// "Share invite" into a permanent failure for exactly those
    /// groups. Losing the rules from the link is bad; losing the
    /// ability to invite anyone is worse.
    ///
    /// Omitted rather than truncated, because truncation is the one
    /// option that produces a wrong answer instead of a missing one:
    /// joiners would sign an abridged text and every one of those
    /// signatures would then fail against the founder's full copy,
    /// reaching them as signatures that don't check out.
    public var linkableRules: String? {
        guard let rules = GroupRules.normalized(invitationMessage) else { return nil }
        return GroupRules.fits(rules) ? rules : nil
    }

    /// Group ID as the raw 32-byte payload (parsed back from `id`).
    /// Used directly when building chain payloads + invitations.
    public var groupIDData: Data {
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

    /// Whether `blsPublicKey` is this group's admin.
    ///
    /// One derivation, shared by every surface that gates on it — the
    /// invite-sharing button, the in-thread join-request rows, and the
    /// chat-list request signal. It had been hand-rolled three times,
    /// and the copies were already drifting.
    ///
    /// Compares against the stored `adminPubkeyHex` rather than
    /// `ownerIdentityID`, which only says "this device's copy of the
    /// thread belongs to that identity" — true for every joiner too.
    /// Groups with no privileged member (`.anarchy`, `.oneOnOne`) carry
    /// no `adminPubkeyHex` and so answer `false` for everyone; callers
    /// that additionally require a particular governance model check
    /// `groupType` themselves.
    public func isAdmin(blsPublicKey: Data) -> Bool {
        guard let storedAdminHex = adminPubkeyHex?.lowercased() else { return false }
        let candidate = blsPublicKey.map { String(format: "%02x", $0) }.joined().lowercased()
        return candidate == storedAdminHex
    }
}
