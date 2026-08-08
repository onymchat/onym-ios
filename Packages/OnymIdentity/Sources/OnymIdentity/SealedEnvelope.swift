import Foundation

/// Wire format for an X25519+AES-GCM-sealed payload received over the
/// Nostr inbox transport. Senders construct one of these per invitation,
/// encode as JSON, and ship the bytes via the inbox transport. The
/// receiver decodes here, then `IdentityRepository.decryptInvitation`
/// runs the X25519 ECDH + HKDF + AES-GCM open against its X25519
/// private key.
///
/// Field names match the stellar-mls reference impl exactly so a
/// stellar-mls sender's invitation decodes here and vice versa.
///
/// Internal to the Identity layer — outside callers pass raw envelope
/// bytes to `IdentityRepository.decryptInvitation(envelopeBytes:)` and
/// receive plaintext bytes back. This struct never crosses that boundary.
public struct SealedEnvelope: Codable, Equatable, Sendable {
    /// Format version; bump when changing wire shape in a non-additive way.
    public let version: Int
    /// Cipher discriminator. Currently only `"x25519-aes-256-gcm-v1"` is
    /// accepted by `decryptInvitation` — the legacy `"aes-256-gcm-v1"`
    /// (group-key broadcast) format is rejected here since this code
    /// path is invitation-only.
    public let scheme: String
    /// Sender's per-invitation X25519 ephemeral public key. Recipient
    /// runs ECDH against their long-term X25519 private key to derive
    /// the AES key.
    public let ephemeralPublicKey: Data?
    /// Ed25519 signature over `ephemeralPublicKey` by the sender's
    /// identity key (M-5 in the stellar-mls codebase). Prevents MITM
    /// substitution of the ephemeral X25519 key. Verified at decrypt
    /// time when present; absent envelopes accept without verification.
    public let ephemeralKeySignature: Data?
    /// Sender's Ed25519 public key embedded in the envelope so the
    /// recipient can verify `ephemeralKeySignature` without out-of-band
    /// key exchange (N-1).
    public let senderEd25519PublicKey: Data?
    /// AES-GCM 12-byte nonce.
    public let nonce: Data?
    /// AES-GCM ciphertext.
    public let ciphertext: Data
    /// AES-GCM 16-byte authentication tag.
    public let authenticationTag: Data?

    public init(
        version: Int,
        scheme: String,
        ephemeralPublicKey: Data?,
        ephemeralKeySignature: Data?,
        senderEd25519PublicKey: Data?,
        nonce: Data?,
        ciphertext: Data,
        authenticationTag: Data?
    ) {
        self.version = version
        self.scheme = scheme
        self.ephemeralPublicKey = ephemeralPublicKey
        self.ephemeralKeySignature = ephemeralKeySignature
        self.senderEd25519PublicKey = senderEd25519PublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }

    enum CodingKeys: String, CodingKey {
        case version, scheme
        case ephemeralPublicKey = "ephemeral_public_key"
        case ephemeralKeySignature = "ephemeral_key_signature"
        case senderEd25519PublicKey = "sender_ed25519_public_key"
        case nonce, ciphertext
        case authenticationTag = "authentication_tag"
    }
}
