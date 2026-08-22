import CryptoKit
import XCTest
@testable import OnymPush

/// The envelope's parameters (X25519 → HKDF-SHA256 with the
/// `onym-push-token-v1` salt → AES-256-GCM) must match the backend's
/// `open_token_envelope`. The Rust side pins an envelope THIS
/// implementation sealed; here the scheme is proven self-consistent
/// and its constants are pinned.
final class PushTokenEnvelopeTests: XCTestCase {
    func testSealedEnvelopeDecryptsWithTheServerKey() throws {
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let token = Data([0x0a, 0x0b, 0x0c, 0x0d, 0xee, 0xff])

        let envelope = try PushTokenEnvelope.seal(
            apnsToken: token,
            serverPublicKey: serverKey.publicKey.rawRepresentation
        )
        XCTAssertEqual(envelope.ephemeralPublicKey.count, 32)
        XCTAssertEqual(envelope.nonce.count, 12)
        XCTAssertEqual(envelope.authenticationTag.count, 16)

        XCTAssertEqual(try open(envelope, with: serverKey), token)
    }

    func testEnvelopeIsNotDecryptableWithAnotherKey() throws {
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let otherKey = Curve25519.KeyAgreement.PrivateKey()
        let envelope = try PushTokenEnvelope.seal(
            apnsToken: Data([0x01]),
            serverPublicKey: serverKey.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try open(envelope, with: otherKey))
    }

    func testSealRefusesAMalformedServerKey() {
        XCTAssertThrowsError(
            try PushTokenEnvelope.seal(apnsToken: Data([0x01]), serverPublicKey: Data([0x02]))
        )
    }

    func testFreshRandomnessPerSeal() throws {
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let first = try PushTokenEnvelope.seal(
            apnsToken: Data([0x01]),
            serverPublicKey: serverKey.publicKey.rawRepresentation
        )
        let second = try PushTokenEnvelope.seal(
            apnsToken: Data([0x01]),
            serverPublicKey: serverKey.publicKey.rawRepresentation
        )
        XCTAssertNotEqual(first.ephemeralPublicKey, second.ephemeralPublicKey)
        XCTAssertNotEqual(first.nonce, second.nonce)
    }

    /// The scheme spelled out independently of the implementation
    /// under test — the salt and info strings are the contract with
    /// the backend, so a drive-by "cleanup" of either fails here.
    private func open(
        _ envelope: PushTokenEnvelope,
        with serverKey: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: envelope.ephemeralPublicKey
        )
        let shared = try serverKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("onym-push-token-v1".utf8),
            sharedInfo: Data("aes-256-gcm".utf8),
            outputByteCount: 32
        )
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: envelope.nonce),
            ciphertext: envelope.ciphertext,
            tag: envelope.authenticationTag
        )
        return try AES.GCM.open(box, using: key)
    }
}
