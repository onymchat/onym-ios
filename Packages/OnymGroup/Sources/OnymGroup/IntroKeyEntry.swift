import Foundation
import OnymIdentity

/// One per-invite ephemeral keypair persisted on the inviter's
/// device. Maps an invite link's `introPublicKey` (the public half
/// shipped in the `IntroCapability` inside the link) to its private
/// counterpart + the metadata needed to dispatch a sealed
/// `GroupInvitationPayload` when an approved request comes in.
///
/// - `introPrivateKey` is X25519 secret material — used to decrypt
///   the joiner's request envelope. Never logged. Per-invite, so
///   leaking one doesn't compromise unrelated invites.
/// - `ownerIdentityID` scopes the entry to the identity that minted
///   the link. Identity removal cascades a `deleteForOwner` so we
///   don't leak intro privkeys past the identity that minted them.
/// - `groupId` is the on-chain `group_id` the invite is for —
///   needed when the inviter's app surfaces "Bob wants to join
///   <group>?" so it can render the group's name.
/// - `createdAt` is display-only; links live until revoked.
/// - `label` is nil for the shared link, else the invitee's fingerprint.
public struct IntroKeyEntry: Equatable, Sendable {
    public let introPublicKey: Data
    public let introPrivateKey: Data
    public let ownerIdentityID: IdentityID
    public let groupId: Data
    public let createdAt: Date
    /// nil == the group's shared link. Non-nil == a create-time offer
    /// aimed at one invitee.
    public let label: String?

    /// True for entries persisted before labels existed. Those decode
    /// with `label == nil`, which is indistinguishable from a shared
    /// link — and on a create-with-invitees group the newest of them is
    /// the LAST INVITEE'S PRIVATE OFFER KEY. Without this flag
    /// `currentOrMint` would adopt it as the group's public link, and
    /// the first rotate would revoke every outstanding legacy invite.
    /// Never adopted, never mass-revoked; listed and individually
    /// revokable like any other superseded key.
    public let isLegacy: Bool

    public init(
        introPublicKey: Data,
        introPrivateKey: Data,
        ownerIdentityID: IdentityID,
        groupId: Data,
        createdAt: Date,
        label: String? = nil,
        isLegacy: Bool = false
    ) {
        precondition(introPublicKey.count == 32,
                     "introPublicKey: expected 32 bytes, got \(introPublicKey.count)")
        precondition(introPrivateKey.count == 32,
                     "introPrivateKey: expected 32 bytes, got \(introPrivateKey.count)")
        precondition(groupId.count == 32,
                     "groupId: expected 32 bytes, got \(groupId.count)")
        self.introPublicKey = introPublicKey
        self.introPrivateKey = introPrivateKey
        self.ownerIdentityID = ownerIdentityID
        self.groupId = groupId
        self.createdAt = createdAt
        self.label = label
        self.isLegacy = isLegacy
    }

    /// First 4 bytes of the inbox key — same fingerprint shape the
    /// approval screen shows.
    static func fingerprint(of inboxPublicKey: Data) -> String {
        inboxPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
