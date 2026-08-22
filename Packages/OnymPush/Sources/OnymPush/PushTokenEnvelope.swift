import CryptoKit
import Foundation

/// The APNs token, encrypted to the push backend's static X25519 key
/// (`x25519-aes-256-gcm-v1`, the invitation scheme's shape with its
/// own HKDF salt) so the raw token never sits readable in a proxy
/// buffer or request body at rest. The Rust counterpart is
/// `open_token_envelope` in `onym-push/apple/src/crypto.rs`.
public struct PushTokenEnvelope: Codable, Sendable, Equatable {
    /// The sealing scheme this envelope implements. Deliberately NOT a
    /// wire field: the backend's `TokenEnvelope` decoder rejects
    /// unknown keys (`deny_unknown_fields`), so adding one requires a
    /// lockstep backend change — and on the wire the scheme is already
    /// identified by the HKDF salt's domain separation (a ciphertext
    /// sealed under any other scheme simply fails to open). If a
    /// second scheme ever ships, versioning moves to the wire in a
    /// coordinated change on both sides.
    public static let scheme = "x25519-aes-256-gcm-v1"

    public let ephemeralPublicKey: Data
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    /// Distinct from the invitation scheme's salt on purpose: a
    /// captured invitation ciphertext and a captured registration
    /// envelope must never be interchangeable inputs.
    private static let hkdfSalt = Data("onym-push-token-v1".utf8)
    private static let hkdfInfo = Data("aes-256-gcm".utf8)

    public init(ephemeralPublicKey: Data, nonce: Data, ciphertext: Data, authenticationTag: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }

    public enum SealError: Error, Equatable {
        /// The fetched registration key is not a 32-byte X25519 key.
        case invalidServerKey
    }

    /// Seal `apnsToken` to the backend's registration key (fetched
    /// from `GET /v1/registration-key` before each register call, so
    /// server-side key rotation needs no client release).
    public static func seal(apnsToken: Data, serverPublicKey: Data) throws -> PushTokenEnvelope {
        guard let serverKey = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: serverPublicKey
        ) else {
            throw SealError.invalidServerKey
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: serverKey)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(apnsToken, using: key)
        return PushTokenEnvelope(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            authenticationTag: sealed.tag
        )
    }
}
