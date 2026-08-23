import Foundation

/// Signing seam: how push registrations get session signatures
/// without this package choosing the key. The private key never
/// crosses the boundary — only the key reference and detached
/// signatures do. Same shape as `ModerationSigner`.
///
/// The signature authenticates the call; the backend verifies the key
/// and discards it, so *any* Ed25519 key will do. The app deliberately
/// supplies a device-local key created for push alone (its
/// `DevicePushSigner`), never an identity's key: an identity-keyed
/// signature would hand the backend persona linkage the payload
/// otherwise avoids.
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
