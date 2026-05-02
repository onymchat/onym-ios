import Foundation

/// Sender-side mirror of `InvitationEnvelopeDecrypting`. The chain
/// interactor that creates a group depends on this seam to wrap each
/// invitee's bootstrap payload in an X25519+AES-GCM-sealed
/// `SealedEnvelope` JSON blob — without ever holding the device's
/// long-term identity keys directly.
///
/// Only the producer of this protocol (i.e. `IdentityRepository`)
/// holds the Ed25519 signing key used to attest the per-envelope
/// ephemeral X25519 pubkey (M-5). The interactor only sees the
/// resulting bytes.
protocol InvitationEnvelopeSealing: Sendable {
    /// Seal `payload` for a single recipient. Generates a fresh
    /// per-envelope X25519 keypair, derives the AES-GCM key via
    /// HKDF-SHA256 over the ECDH shared secret with
    /// `recipientInboxPublicKey` (32-byte raw X25519 pubkey), encrypts
    /// the payload with a random nonce, signs the ephemeral pubkey
    /// with the sender's Ed25519 identity key (M-5), and returns the
    /// JSON-encoded `SealedEnvelope` bytes ready to drop on
    /// `InboxTransport.send(...)`.
    ///
    /// Throws on: missing identity, malformed recipient pubkey,
    /// signing failure, encryption failure.
    func sealInvitation(
        payload: Data,
        to recipientInboxPublicKey: Data
    ) async throws -> Data
}

enum InvitationSealError: Error, Equatable, Sendable {
    case identityNotLoaded
    case invalidRecipientPublicKey
    case signingFailed
    case encryptionFailed
    case encodingFailed
}
