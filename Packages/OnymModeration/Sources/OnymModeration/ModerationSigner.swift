import Foundation

/// Identity seam: how moderation objects get user signatures without
/// this package depending on OnymIdentity. The app target adapts
/// `IdentityRepository` behind this — the private key never crosses
/// the boundary, only detached signatures do.
public protocol ModerationSigner: Sendable {
    /// The user's identity key reference as mandates carry it:
    /// `onym:key:<hex>`. Follows the currently-selected identity.
    func userKeyID() async throws -> String
    /// Ed25519 detached signature over `message` with the
    /// currently-selected identity's key. Only for payloads whose
    /// `userKey` field came from `userKeyID()` in the same flow.
    func sign(_ message: Data) async throws -> Data
    /// Ed25519 detached signature over `message` with the key that
    /// `userKey` names (`onym:key:<hex>`), regardless of which
    /// identity is currently selected. Payloads that name
    /// `mandate.user` MUST be signed through this: the device can
    /// hold several identities, and a session that presents the
    /// mandate's identity but carries another identity's signature is
    /// refused by the backend as `signature_invalid`.
    ///
    /// Throws `ModerationError.signingKeyUnavailable` — and only that
    /// — when the named key is not available to sign with: absent
    /// from this device, or held in quarantine after a fresh-install
    /// verdict. Quarantine is deliberately included. Recovering a
    /// quarantined identity takes a mnemonic restore or a flow that
    /// does not exist yet; it will not come back while the app waits,
    /// which is the distinction this error draws. Conforming adapters
    /// MUST NOT use it for a failure that clears on its own (an
    /// unreadable Keychain, a store that didn't load): callers treat
    /// it as terminal and stop waiting.
    func sign(_ message: Data, as userKey: String) async throws -> Data
}
