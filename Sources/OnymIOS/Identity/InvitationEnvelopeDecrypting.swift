import Foundation

/// Narrow seam the inbox-side interactor depends on instead of the
/// whole `IdentityRepository`. Lets test fakes substitute a canned
/// decrypter without standing up a real identity, and keeps the
/// secret-material rule honest: only the producer of this protocol
/// (i.e. `IdentityRepository`) ever holds the X25519 private key.
protocol InvitationEnvelopeDecrypting: Sendable {
    /// Decode `envelopeBytes` (a JSON-serialised `SealedEnvelope`) and
    /// open the AES-GCM ciphertext using the X25519 private key derived
    /// from the on-device identity. Returns the plaintext bytes.
    ///
    /// Throws on: malformed JSON, wrong scheme, missing identity,
    /// invalid signature on the ephemeral key (when present), or
    /// AES-GCM tag mismatch.
    func decryptInvitation(envelopeBytes: Data) async throws -> Data
}

enum InvitationDecryptError: Error, Equatable, Sendable {
    case identityNotLoaded
    case malformedEnvelope
    case unsupportedScheme(String)
    case missingEphemeralKey
    case missingNonceOrTag
    case signatureVerificationFailed
    case decryptionFailed
}
