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
struct SealedEnvelope: Codable, Equatable, Sendable {
    /// Format version; bump when changing wire shape in a non-additive way.
    let version: Int
    /// Cipher discriminator. Currently only `"x25519-aes-256-gcm-v1"` is
    /// accepted by `decryptInvitation` — the legacy `"aes-256-gcm-v1"`
    /// (group-key broadcast) format is rejected here since this code
    /// path is invitation-only.
    let scheme: String
    /// Sender's per-invitation X25519 ephemeral public key. Recipient
    /// runs ECDH against their long-term X25519 private key to derive
    /// the AES key.
    let ephemeralPublicKey: Data?
    /// Ed25519 signature over `ephemeralPublicKey` by the sender's
    /// identity key (M-5 in the stellar-mls codebase). Prevents MITM
    /// substitution of the ephemeral X25519 key. Verified at decrypt
    /// time when present; absent envelopes accept without verification.
    let ephemeralKeySignature: Data?
    /// Sender's Ed25519 public key embedded in the envelope so the
    /// recipient can verify `ephemeralKeySignature` without out-of-band
    /// key exchange (N-1).
    let senderEd25519PublicKey: Data?
    /// AES-GCM 12-byte nonce.
    let nonce: Data?
    /// AES-GCM ciphertext.
    let ciphertext: Data
    /// AES-GCM 16-byte authentication tag.
    let authenticationTag: Data?

    enum CodingKeys: String, CodingKey {
        case version, scheme
        case ephemeralPublicKey = "ephemeral_public_key"
        case ephemeralKeySignature = "ephemeral_key_signature"
        case senderEd25519PublicKey = "sender_ed25519_public_key"
        case nonce, ciphertext
        case authenticationTag = "authentication_tag"
    }
}
