import Foundation
import OnymIdentity
import OnymModeration

/// Adapts `IdentityRepository` to the moderation package's signer
/// seam. The mandate's `user` key is the identity's derived Stellar
/// Ed25519 public key (`onym:key:<hex>`); signatures come from the
/// matching private key, which never leaves the repository.
struct IdentityModerationSigner: ModerationSigner {
    let repository: IdentityRepository

    func userKeyID() async throws -> String {
        guard let identity = await repository.currentIdentity() else {
            throw ModerationError.notImplemented("no identity bootstrapped yet")
        }
        let hex = identity.stellarPublicKey.map { String(format: "%02x", $0) }.joined()
        return "onym:key:\(hex)"
    }

    func sign(_ message: Data) async throws -> Data {
        try await repository.signWithStellarKey(message)
    }

    /// Maps the one terminal signing failure onto the seam's own
    /// error. `OnymModeration` cannot see `IdentityError`, so without
    /// this translation "this device does not hold that key" and "the
    /// Keychain read failed this once" arrive as the same opaque
    /// `Error` — and a caller that must tell a permanent state from a
    /// transient one has nothing to match on. Every other failure
    /// passes through unchanged, so it keeps being treated as
    /// retryable.
    func sign(_ message: Data, as userKey: String) async throws -> Data {
        let hex = userKey.hasPrefix("onym:key:")
            ? String(userKey.dropFirst("onym:key:".count))
            : userKey
        do {
            return try await repository.signWithStellarKey(
                message,
                matchingPublicKeyHex: hex
            )
        } catch let IdentityError.noIdentityForKey(missing) {
            throw ModerationError.signingKeyUnavailable(missing)
        }
    }
}
