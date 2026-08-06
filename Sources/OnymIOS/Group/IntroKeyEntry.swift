import Foundation

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
struct IntroKeyEntry: Equatable, Sendable {
    let introPublicKey: Data
    let introPrivateKey: Data
    let ownerIdentityID: IdentityID
    let groupId: Data
    let createdAt: Date
    /// nil == the group's shared link. Non-nil == a create-time offer
    /// aimed at one invitee.
    let label: String?

    init(
        introPublicKey: Data,
        introPrivateKey: Data,
        ownerIdentityID: IdentityID,
        groupId: Data,
        createdAt: Date,
        label: String? = nil
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
    }

    /// First 4 bytes of the inbox key — same fingerprint shape the
    /// approval screen shows.
    static func fingerprint(of inboxPublicKey: Data) -> String {
        inboxPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
