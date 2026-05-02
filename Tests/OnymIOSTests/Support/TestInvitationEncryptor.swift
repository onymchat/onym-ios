import CryptoKit
import Foundation
@testable import OnymIOS

/// Test-only helper that produces real `SealedEnvelope` ciphertext so
/// `IdentityRepositoryInvitationDecryptTests` can do an end-to-end
/// round-trip without porting the sender-side `encryptInvitation` to
/// production code (no app code needs to *send* invitations yet).
///
/// Mirrors the stellar-mls `GroupCrypto.encryptInvitation` formula
/// exactly: ephemeral X25519 keypair, ECDH against the recipient's
/// X25519 public key, HKDF with the same salt+info as the production
/// decrypter, AES-GCM seal. Optional Ed25519 signature over the
/// ephemeral pubkey when `senderSigningKey` is provided (for M-5
/// signature-verification tests).
enum TestInvitationEncryptor {
    /// Build a `SealedEnvelope` and JSON-encode it to the byte form a
    /// real inbox-transport message would carry.
    static func envelopeBytes(
        plaintext: Data,
        recipientX25519PublicKey: Data,
        senderSigningKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> Data {
        let envelope = try sealedEnvelope(
            plaintext: plaintext,
            recipientX25519PublicKey: recipientX25519PublicKey,
            senderSigningKey: senderSigningKey
        )
        return try JSONEncoder().encode(envelope)
    }

    static func sealedEnvelope(
        plaintext: Data,
        recipientX25519PublicKey: Data,
        senderSigningKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> SealedEnvelope {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let recipientPubkey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: recipientX25519PublicKey
        )

        let sharedSecret = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPubkey)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("sep-invitation-v1".utf8),
            sharedInfo: Data("aes-256-gcm".utf8),
            outputByteCount: 32
        )

        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        let ephPubData = Data(ephemeral.publicKey.rawRepresentation)
        let ephKeySignature: Data?
        let senderPubData: Data?
        if let signingKey = senderSigningKey {
            ephKeySignature = try signingKey.signature(for: ephPubData)
            senderPubData = Data(signingKey.publicKey.rawRepresentation)
        } else {
            ephKeySignature = nil
            senderPubData = nil
        }

        return SealedEnvelope(
            version: 1,
            scheme: "x25519-aes-256-gcm-v1",
            ephemeralPublicKey: ephPubData,
            ephemeralKeySignature: ephKeySignature,
            senderEd25519PublicKey: senderPubData,
            nonce: Data(nonce),
            ciphertext: sealed.ciphertext,
            authenticationTag: sealed.tag
        )
    }
}
