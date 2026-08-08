import Foundation

/// Identity seam: how moderation objects get user signatures without
/// this package depending on OnymIdentity. The app target adapts
/// `IdentityRepository` behind this — the private key never crosses
/// the boundary, only detached signatures do.
public protocol ModerationSigner: Sendable {
    /// The user's identity key reference as mandates carry it:
    /// `onym:key:<hex>`.
    func userKeyID() async throws -> String
    /// Ed25519 detached signature over `message`.
    func sign(_ message: Data) async throws -> Data
}
