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
/// - `createdAt` drives both the enforced TTL (`lifetime`) and the
///   share screen's reuse-or-mint decision.
struct IntroKeyEntry: Equatable, Sendable {
    /// How long a minted invite link stays honored — 24 hours per
    /// issue onymchat/onym-ios#111. Mirrors onym-android's
    /// `IntroKeyEntry.LIFETIME_MILLIS`.
    ///
    /// This window is the only bound on a link: it is redeemable by
    /// any number of joiners until it expires. Nothing retires a key
    /// early — `KeychainIntroKeyStore` filters expired entries out at
    /// its single read point, and neither Approve nor Decline revokes.
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

    /// `true` while this entry is still inside its 24h window.
    ///
    /// `KeychainIntroKeyStore.loadAll` enforces the same rule at its
    /// single read point, with the matching strict comparison so the
    /// two boundaries can't drift. `InviteIntroducer.currentOrMint`
    /// re-checks here rather than trusting the store, which keeps the
    /// reuse-or-mint decision a pure function of the entry and a clock
    /// — and therefore reachable from `InMemoryIntroKeyStore`, which
    /// has no TTL of its own.
    func isLive(at now: Date) -> Bool {
        now.timeIntervalSince(createdAt) < Self.lifetime
    }
}
