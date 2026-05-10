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
/// - `createdAt` drives time-based expiry. Entries older than
///   `IntroKeyEntry.lifetime` are treated as revoked at the
///   `IntroKeyStore` boundary (`find` returns nil, `listForOwner`
///   and the entries stream omit them) and lazily purged on the
///   next read.
struct IntroKeyEntry: Equatable, Sendable {
    /// How long an invite link is honored after minting. Issue #111:
    /// rotate every 24 hours to shrink the leak window of a forwarded
    /// or screenshotted link.
    static let lifetime: TimeInterval = 24 * 60 * 60

    let introPublicKey: Data
    let introPrivateKey: Data
    let ownerIdentityID: IdentityID
    let groupId: Data
    let createdAt: Date

    init(
        introPublicKey: Data,
        introPrivateKey: Data,
        ownerIdentityID: IdentityID,
        groupId: Data,
        createdAt: Date
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
    }

    func isExpired(at instant: Date, lifetime: TimeInterval = IntroKeyEntry.lifetime) -> Bool {
        instant.timeIntervalSince(createdAt) >= lifetime
    }
}
