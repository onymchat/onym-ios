import Foundation

/// Identity seam: how push registrations get user signatures without
/// this package depending on OnymIdentity. The app target adapts
/// `IdentityRepository` behind this — the private key never crosses
/// the boundary, only detached signatures do. Same shape as
/// `ModerationSigner`.
///
/// The signature authenticates the call; the backend verifies the key
/// and discards it. Which identity signs is therefore immaterial to
/// the backend — any currently-persisted identity's key will do.
public protocol PushSigner: Sendable {
    /// The signing identity's key reference: `onym:key:<hex>`.
    func userKeyID() async throws -> String
    /// Ed25519 detached signature over `message` with that key.
    func sign(_ message: Data) async throws -> Data
}

/// Attestation seam, mirroring the moderation package's provider: a
/// fresh `DCDevice` token per call, or nil where attestation does not
/// exist (simulator, enterprise build). The client never fabricates
/// one.
public protocol PushDeviceAttestationProvider: Sendable {
    func currentToken() async -> Data?
}
