import CryptoKit
import Foundation

/// Opens the envelope a broker seals a `SeatEntitlement` into.
///
/// Same construction as the invitation envelope — X25519 ECDH, HKDF, an
/// Ed25519 signature over the ephemeral key, AES-GCM — with a **different
/// scheme string and a different HKDF salt**, and that difference is the
/// point. Reusing the invitation suite verbatim would make an
/// entitlement ciphertext and an invitation ciphertext interchangeable
/// at the crypto layer: the same key agreement, the same derivation
/// context, the same sender-key slot, with only a field name separating
/// two unrelated trust relationships. A distinct suite costs one
/// constant and buys real domain separation.
public enum SeatSealedEnvelope {
    public static let scheme = "x25519-aes-256-gcm-seat-v1"
    static let hkdfSalt = Data("onym-seat-entitlement-v1".utf8)
    static let sharedInfo = Data("aes-256-gcm".utf8)

    /// Wire shape, snake_case to match the sealed-envelope format that
    /// already exists on this transport. Everything *outside* the
    /// envelope stays camelCase; this looks like an inconsistency and is
    /// not one.
    struct Wire: Decodable {
        let version: Int
        let scheme: String
        let ephemeralPublicKey: Data
        let ephemeralKeySignature: Data?
        let senderEd25519PublicKey: Data?
        let nonce: Data
        let ciphertext: Data
        let authenticationTag: Data

        enum CodingKeys: String, CodingKey {
            case version, scheme, nonce, ciphertext
            case ephemeralPublicKey = "ephemeral_public_key"
            case ephemeralKeySignature = "ephemeral_key_signature"
            case senderEd25519PublicKey = "sender_ed25519_public_key"
            case authenticationTag = "authentication_tag"
        }
    }

    /// Open an envelope addressed to `recipient`.
    ///
    /// `expectedSenders` are the broker keys the operator declares in
    /// its signed manifest. Passing an empty set means "accept an
    /// unauthenticated envelope", which is a decision a caller has to
    /// make explicitly rather than inherit from a default — the whole
    /// value of the sender check is lost if it can be skipped by
    /// omission.
    ///
    /// A present-but-invalid signature throws rather than degrading to
    /// "unsigned": an envelope claiming a sender it cannot prove is
    /// worse than one claiming none.
    public static func open(
        envelopeBytes: Data,
        recipient: Curve25519.KeyAgreement.PrivateKey,
        expectedSenders: [Curve25519.Signing.PublicKey]
    ) throws -> Data {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: envelopeBytes) else {
            throw BillingError.envelopeUnreadable
        }
        guard wire.version == 1, wire.scheme == scheme else {
            // An invitation envelope arriving here, or a future suite:
            // both are refused rather than attempted.
            throw BillingError.envelopeUnreadable
        }
        guard
            let ephemeral = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: wire.ephemeralPublicKey)
        else {
            throw BillingError.envelopeUnreadable
        }

        if let signature = wire.ephemeralKeySignature {
            guard
                let senderBytes = wire.senderEd25519PublicKey,
                let sender = try? Curve25519.Signing.PublicKey(rawRepresentation: senderBytes),
                sender.isValidSignature(signature, for: wire.ephemeralPublicKey)
            else {
                throw BillingError.envelopeUnreadable
            }
            if !expectedSenders.isEmpty,
               !expectedSenders.contains(where: { $0.rawRepresentation == sender.rawRepresentation }) {
                throw BillingError.envelopeUnreadable
            }
        } else if !expectedSenders.isEmpty {
            // We were told who this must come from, and it does not say.
            throw BillingError.envelopeUnreadable
        }

        guard
            let shared = try? recipient.sharedSecretFromKeyAgreement(with: ephemeral)
        else {
            throw BillingError.envelopeUnreadable
        }
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: sharedInfo,
            outputByteCount: 32
        )
        guard
            let box = try? AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: wire.nonce),
                ciphertext: wire.ciphertext,
                tag: wire.authenticationTag
            ),
            let plaintext = try? AES.GCM.open(box, using: key)
        else {
            throw BillingError.envelopeUnreadable
        }
        return plaintext
    }
}
