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
}
