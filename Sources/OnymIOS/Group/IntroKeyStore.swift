import Foundation

/// Persistence seam for per-invite ephemeral X25519 keypairs.
///
/// Lifecycle of one entry:
///
///  1. Sender taps "Share invite" → app mints a fresh X25519 keypair
///     via `InviteIntroducer.mint`, persists via `save`.
///  2. Joiner taps the deeplink → app sends a request envelope
///     encrypted to `IntroKeyEntry.introPublicKey` over Nostr.
///  3. Sender's intro-inbox fan-out (PR-3) receives → calls `find`
///     with the targeted introPublicKey → uses
///     `IntroKeyEntry.introPrivateKey` to decrypt the request
///     payload.
///  4. On Approve, sender seals the existing
///     `GroupInvitationPayload` to the joiner's identity inbox key.
///     `revoke` is called to retire the intro slot.
///
/// Owner-scoping: every entry carries an `IdentityID`. Removing an
/// identity cascades a `deleteForOwner` so we don't leak intro
/// privkeys past the identity that minted them — wired in PR-3 via
/// `IdentityRepository`'s removal listeners.
protocol IntroKeyStore: Sendable {
    /// Persist a freshly-minted intro entry. Idempotent on
    /// `IntroKeyEntry.introPublicKey` — re-mint with the same pub
    /// is a no-op (shouldn't happen in practice; X25519 keypairs
    /// are uniformly random).
    func save(_ entry: IntroKeyEntry) async

    /// Look up an entry by its public key. Returns nil when the
    /// pubkey is unknown — happens when an old entry was
    /// `revoke`d, or when a request envelope targets a pubkey
    /// this device never minted (probably a forged link).
    func find(introPublicKey: Data) async -> IntroKeyEntry?

    /// Every entry minted by `ownerIdentityID`. Sorted newest
    /// first by `IntroKeyEntry.createdAt`. UI's "Active invites"
    /// list reads here.
    func listForOwner(_ ownerIdentityID: IdentityID) async -> [IntroKeyEntry]

    /// Single-entry deletion. Called after a request is accepted +
    /// sealed → the intro slot is no longer useful. No-op if the
    /// pubkey isn't present.
    func revoke(introPublicKey: Data) async

    /// Cascade for the identity-removal flow. Returns the count of
    /// entries deleted so the caller can log the cleanup size.
    /// Hooked into `IdentityRepository`'s removal listeners.
    @discardableResult
    func deleteForOwner(_ ownerIdentityID: IdentityID) async -> Int

    /// Hot stream of every entry owned by `ownerIdentityID`. New
    /// subscribers get the current snapshot first; subsequent
    /// emissions follow `save` / `revoke` / `deleteForOwner` calls.
    /// Sorted newest-first by `createdAt`. `IntroInboxPump` subscribes
    /// here so adding/revoking an invite immediately re-balances the
    /// transport subscription set.
    nonisolated func entriesStream(forOwner ownerIdentityID: IdentityID) -> AsyncStream<[IntroKeyEntry]>
}
