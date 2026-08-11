import CryptoKit
import XCTest
import OnymChatsCore

/// The cross-implementation vector for the version 2 media commitment.
///
/// This side is the signer; the Authority (Rust) is the verifier. They
/// agree on these bytes by construction — two encoders, two languages,
/// a format that exists as prose rather than a schema — so nothing else
/// in either repository would notice them drifting apart. Without a
/// shared vector, the first symptom of drift is every photo report
/// failing authentication in production, with both sides' own tests
/// still green.
///
/// An identical copy lives at `onym-moderation/authority/fixtures/`.
/// Changing one without the other must break both sides.
///
/// The fixture is read from disk by path rather than as a bundle
/// resource, so it stays a plain file two repositories can diff.
final class MediaCommitmentFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Inputs: Decodable {
            struct Media: Decodable {
                let blobSha256: String
                let mimeType: String
                let plaintextSha256: String
                let plaintextByteLength: Int
                let width: Int
                let height: Int
            }
            let messageId: String
            let groupId: String
            let groupSecretHex: String
            let sentAtMillis: Int64
            let body: String
            let media: [Media]
        }
        let inputs: Inputs
        let preimage: String
        let signerPublicKeyHex: String
        let signatureBase64: String
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/media-commitment-v2.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// The producer side: feeding the vector's inputs through the real
    /// signing path must reproduce its bytes exactly. This is the test
    /// that fails if the preimage shape, key order, or escaping ever
    /// changes here.
    func test_theSignerReproducesTheSharedVectorBytes() throws {
        let fixture = try fixture()
        let inputs = fixture.inputs

        let preimage = try ChatModerationProof.signedContent(
            messageID: try XCTUnwrap(UUID(uuidString: inputs.messageId)),
            groupID: inputs.groupId,
            groupSecret: try XCTUnwrap(Data(hexString: inputs.groupSecretHex)),
            sentAtMillis: inputs.sentAtMillis,
            body: inputs.body,
            media: inputs.media.map {
                ChatModerationProof.MediaCommitment(
                    blobSha256: $0.blobSha256,
                    mimeType: $0.mimeType,
                    plaintextSha256: $0.plaintextSha256,
                    plaintextByteLength: $0.plaintextByteLength,
                    width: $0.width,
                    height: $0.height
                )
            }
        )

        XCTAssertEqual(
            preimage,
            fixture.preimage,
            "the signer no longer produces the bytes the Authority verifies against"
        )
    }

    /// And the vector's own signature verifies over those bytes, the
    /// same way the Authority checks a real one — over the disclosed
    /// string verbatim, never a re-encoding of it.
    func test_theSharedVectorSignatureVerifies() throws {
        let fixture = try fixture()
        let key = try Curve25519.Signing.PublicKey(
            rawRepresentation: try XCTUnwrap(Data(hexString: fixture.signerPublicKeyHex))
        )
        let signature = try XCTUnwrap(Data(base64Encoded: fixture.signatureBase64))

        XCTAssertTrue(key.isValidSignature(signature, for: Data(fixture.preimage.utf8)))
    }

    /// The escaped slash is load-bearing, not cosmetic. This encoder
    /// does not set `withoutEscapingSlashes`, so a MIME type is signed
    /// as `image\/jpeg`. Since the signature covers these bytes
    /// verbatim, "tidying" the escaping on either side would invalidate
    /// every proof already produced.
    func test_theMediaTypeSlashIsEscapedInTheSignedBytes() throws {
        XCTAssertTrue(try fixture().preimage.contains(#"image\/jpeg"#))
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
