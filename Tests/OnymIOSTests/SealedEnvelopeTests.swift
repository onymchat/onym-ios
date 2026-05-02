import XCTest
@testable import OnymIOS

/// Pin the SealedEnvelope wire format. Cross-platform interop with the
/// stellar-mls reference impl rides on these JSON field names — a
/// silent rename here would break a stellar-mls sender's invitations.
final class SealedEnvelopeTests: XCTestCase {

    // MARK: - JSON field names (cross-platform contract)

    func test_jsonEncoding_usesSnakeCaseFieldNames() throws {
        let envelope = SealedEnvelope(
            version: 1,
            scheme: "x25519-aes-256-gcm-v1",
            ephemeralPublicKey: Data([0x01]),
            ephemeralKeySignature: Data([0x02]),
            senderEd25519PublicKey: Data([0x03]),
            nonce: Data([0x04]),
            ciphertext: Data([0x05]),
            authenticationTag: Data([0x06])
        )
        let json = try JSONEncoder().encode(envelope)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])

        XCTAssertNotNil(dict["ephemeral_public_key"], "renaming this breaks stellar-mls interop")
        XCTAssertNotNil(dict["ephemeral_key_signature"])
        XCTAssertNotNil(dict["sender_ed25519_public_key"])
        XCTAssertNotNil(dict["authentication_tag"])
        // Camel-case keys must NOT appear.
        XCTAssertNil(dict["ephemeralPublicKey"])
        XCTAssertNil(dict["ephemeralKeySignature"])
        XCTAssertNil(dict["senderEd25519PublicKey"])
        XCTAssertNil(dict["authenticationTag"])
    }

    // MARK: - Roundtrip

    func test_roundtripsThroughJSONCoder() throws {
        let original = SealedEnvelope(
            version: 1,
            scheme: "x25519-aes-256-gcm-v1",
            ephemeralPublicKey: Data((0..<32).map { UInt8($0) }),
            ephemeralKeySignature: Data((0..<64).map { UInt8($0) }),
            senderEd25519PublicKey: Data((0..<32).map { UInt8($0 ^ 0x55) }),
            nonce: Data((0..<12).map { UInt8($0) }),
            ciphertext: Data("hello".utf8),
            authenticationTag: Data((0..<16).map { UInt8($0) })
        )
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SealedEnvelope.self, from: json)
        XCTAssertEqual(decoded, original)
    }

    func test_decodesEnvelopeWithMissingOptionalFields() throws {
        // Older stellar-mls senders may omit the M-5 signature fields.
        let json = """
        {
            "version": 1,
            "scheme": "x25519-aes-256-gcm-v1",
            "ephemeral_public_key": "AQ==",
            "nonce": "AAECAwQFBgcICQoL",
            "ciphertext": "aGVsbG8=",
            "authentication_tag": "AAECAwQFBgcICQoLDA0ODw=="
        }
        """
        let decoded = try JSONDecoder().decode(SealedEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.scheme, "x25519-aes-256-gcm-v1")
        XCTAssertNotNil(decoded.ephemeralPublicKey)
        XCTAssertNil(decoded.ephemeralKeySignature)
        XCTAssertNil(decoded.senderEd25519PublicKey)
    }
}
