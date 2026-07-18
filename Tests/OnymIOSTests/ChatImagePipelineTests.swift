import UIKit
import XCTest
@testable import OnymIOS

/// Phase 1 coverage for the image pipeline: AES-GCM blob crypto, the
/// BlurHash placeholder codec, and the Blossom BUD-01 auth header.
final class ChatImagePipelineTests: XCTestCase {

    // MARK: - ChatImageCrypto

    func test_crypto_sealOpen_roundTrips() throws {
        let plaintext = Data((0..<5000).map { UInt8($0 & 0xFF) })
        let sealed = try ChatImageCrypto.seal(plaintext)
        XCTAssertEqual(sealed.key.count, 32)
        XCTAssertEqual(sealed.sha256Hex, ChatImageCrypto.sha256Hex(sealed.blob))

        let opened = try ChatImageCrypto.open(
            blob: sealed.blob, key: sealed.key, expectedSha256Hex: sealed.sha256Hex
        )
        XCTAssertEqual(opened, plaintext)
    }

    func test_crypto_open_hashMismatch_throws() throws {
        let sealed = try ChatImageCrypto.seal(Data(repeating: 0xAB, count: 100))
        XCTAssertThrowsError(
            try ChatImageCrypto.open(
                blob: sealed.blob, key: sealed.key, expectedSha256Hex: String(repeating: "00", count: 32)
            )
        ) { error in
            XCTAssertEqual(error as? ChatImageCrypto.CryptoError, .hashMismatch)
        }
    }

    // MARK: - Blurhash

    func test_blurhash_encodeThenDecode_producesImage() {
        let image = solidImage(color: .systemTeal, size: CGSize(width: 64, height: 48))
        guard let hash = Blurhash.encode(image) else {
            return XCTFail("blurhash encode returned nil")
        }
        XCTAssertFalse(hash.isEmpty)
        // First char encodes the component grid (4×3 default → flag 20).
        let decoded = Blurhash.decode(hash, size: CGSize(width: 32, height: 24))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.size.width, 32)
        XCTAssertEqual(decoded?.size.height, 24)
    }

    func test_blurhash_decode_malformed_returnsNil() {
        XCTAssertNil(Blurhash.decode("!", size: CGSize(width: 8, height: 8)))
    }

    // MARK: - Image encoder

    func test_encoder_downscalesAndProducesBlurhash() {
        let big = solidImage(color: .systemPink, size: CGSize(width: 4000, height: 3000))
        guard let encoded = ChatImageEncoder.encode(big) else {
            return XCTFail("encode returned nil")
        }
        XCTAssertLessThanOrEqual(max(encoded.width, encoded.height), Int(ChatImageEncoder.maxEdge))
        XCTAssertEqual(encoded.width, 2048)
        XCTAssertEqual(encoded.height, 1536)
        XCTAssertFalse(encoded.blurhash.isEmpty)
        XCTAssertLessThanOrEqual(encoded.jpeg.count, ChatImageEncoder.maxBytes)
    }

    // MARK: - Blossom auth (BUD-01)

    func test_blossomAuthHeader_isSignedKind24242OverBlobHash() throws {
        let signer = try OnymNostrSigner(secretKey: Data(repeating: 0xEF, count: 32))
        let sha = String(repeating: "ab", count: 32)
        let header = try URLSessionBlossomClient.authorizationHeader(
            action: "upload", sha256: sha, ttlSeconds: 300, signer: signer
        )
        XCTAssertTrue(header.hasPrefix("Nostr "))
        let b64 = String(header.dropFirst("Nostr ".count))
        let json = try XCTUnwrap(Data(base64Encoded: b64))
        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        XCTAssertEqual(event.kind, 24242)
        XCTAssertTrue(event.tags.contains(["t", "upload"]))
        XCTAssertTrue(event.tags.contains(["x", sha]))
        XCTAssertTrue(event.tags.contains { $0.first == "expiration" })
        XCTAssertFalse(event.sig.isEmpty)
    }

    // MARK: - ChatImageLoader

    func test_loader_downloadsDecryptsAndCaches() async throws {
        let encoded = try XCTUnwrap(ChatImageEncoder.encode(
            solidImage(color: .systemIndigo, size: CGSize(width: 40, height: 30))
        ))
        let sealed = try ChatImageCrypto.seal(encoded.jpeg)
        let blossom = FakeBlossomClient()
        _ = try await blossom.upload(sealed.blob, mimeType: "image/jpeg")

        let attachment = ChatImageAttachment(
            sha256: sealed.sha256Hex, mimeType: "image/jpeg", byteSize: sealed.blob.count,
            width: encoded.width, height: encoded.height, encKey: sealed.key,
            blurhash: encoded.blurhash, server: nil
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("loadertest-\(UUID().uuidString)")
        let loader = ChatImageLoader(blossomClient: blossom, cacheDirectory: tmp)

        let image = try await loader.image(for: attachment)
        XCTAssertGreaterThan(image.size.width, 0)
        // Cached on disk → resolvable even if the server "goes away".
        await blossom.setFailing(true)
        let again = try await loader.image(for: attachment)
        XCTAssertEqual(again.size, image.size)
    }

    // MARK: - Helpers

    private func solidImage(color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
