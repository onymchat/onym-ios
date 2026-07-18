import XCTest
@testable import OnymIOS

/// Wire-format coverage for the video attachment added to
/// `ChatMessagePayload` (Blossom video messages).
final class ChatVideoAttachmentTests: XCTestCase {

    private func samplePoster() -> ChatImageAttachment {
        ChatImageAttachment(
            sha256: String(repeating: "cd", count: 32),
            mimeType: "image/jpeg",
            byteSize: 40_000,
            width: 1280,
            height: 720,
            encKey: Data(repeating: 0x11, count: 32),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
            server: "https://blossom.onym.app"
        )
    }

    private func sampleAttachment() -> ChatVideoAttachment {
        ChatVideoAttachment(
            sha256: String(repeating: "ab", count: 32),
            mimeType: "video/mp4",
            byteSize: 4_200_000,
            width: 1280,
            height: 720,
            durationSeconds: 12.5,
            encKey: Data(repeating: 0x22, count: 32),
            poster: samplePoster(),
            server: "https://blossom.onym.app"
        )
    }

    private func makePayload(video: ChatVideoAttachment?) -> ChatMessagePayload {
        ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: Data(repeating: 0x22, count: 32),
            senderBlsPubkeyHex: String(repeating: "cd", count: 48),
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: nil,
            variant: .tyranny(body: "watch this"),
            videoAttachment: video
        )
    }

    func test_payload_withVideo_roundTrips() throws {
        let payload = makePayload(video: sampleAttachment())
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.videoAttachment?.sha256, payload.videoAttachment?.sha256)
        XCTAssertEqual(decoded.videoAttachment?.encKey, Data(repeating: 0x22, count: 32))
        // The poster rides inside the video attachment with its own key.
        XCTAssertEqual(decoded.videoAttachment?.poster.encKey, Data(repeating: 0x11, count: 32))
        XCTAssertEqual(decoded.videoAttachment?.durationSeconds, 12.5)

        // snake_case wire keys.
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"video_attachment\""))
        XCTAssertTrue(json.contains("\"duration_seconds\""))
        XCTAssertTrue(json.contains("\"poster\""))
        XCTAssertTrue(json.contains("\"enc_key\""))
    }

    func test_payload_withoutVideo_isNil() throws {
        let payload = makePayload(video: nil)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: data)
        XCTAssertNil(decoded.videoAttachment)
    }

    /// Back-compat: a payload minted by an older sender (no
    /// `video_attachment` key) must decode to `nil`, not throw.
    func test_payload_legacyWithoutVideoKey_decodesToNil() throws {
        let legacyJSON = """
        {
          "version": 1,
          "message_id": "\(UUID().uuidString)",
          "group_id": "\(Data(repeating: 0x22, count: 32).base64EncodedString())",
          "sender_bls_pubkey_hex": "\(String(repeating: "cd", count: 48))",
          "sent_at_millis": 1700000000000,
          "variant": { "kind": "tyranny", "body": "hi" }
        }
        """
        let decoded = try JSONDecoder().decode(
            ChatMessagePayload.self, from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(decoded.videoAttachment)
        XCTAssertNil(decoded.attachment)
        XCTAssertEqual(decoded.variant.body, "hi")
    }
}
