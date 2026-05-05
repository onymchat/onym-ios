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
    let name: String
    /// 32-byte shared secret. Used for `topicTag` derivation and message
    /// key HKDF — both still TBD on iOS, but the value must be sealed
    /// into the invitation now so receivers can rebuild the same key.
    let groupSecret: Data
    let createdAt: Date

    var members: [GovernanceMember]
    /// View-facing supplement to `members`, keyed by lowercase BLS
    /// pubkey hex. Populated for the creator at group-create time and
    /// extended as new members announce themselves (post-PR fanout).
    /// May be sparser than `members` — a member without a profile is
    /// still a valid roster entry, just one we can't render by name
    /// yet. The reverse must never hold: every key here MUST appear
    /// in `members`.
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
    /// Flips to `true` once the relayer's `create_group_v2` returns
    /// `accepted = true`. Persisted-but-not-anchored groups can be
    /// retried.
    var isPublishedOnChain: Bool

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
