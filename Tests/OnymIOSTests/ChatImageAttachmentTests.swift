import XCTest
@testable import OnymIOS

/// Wire-format coverage for the image attachment added to
/// `ChatMessagePayload` (Blossom image messages, Phase 0).
final class ChatImageAttachmentTests: XCTestCase {

    private func sampleAttachment() -> ChatImageAttachment {
        ChatImageAttachment(
            sha256: String(repeating: "ab", count: 32),
            mimeType: "image/jpeg",
            byteSize: 40_000,
            width: 1920,
            height: 1080,
            encKey: Data(repeating: 0x11, count: 32),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj",
            server: "https://blossom.onym.app"
        )
    }

    private func makePayload(attachment: ChatImageAttachment?) -> ChatMessagePayload {
        ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: Data(repeating: 0x22, count: 32),
            senderBlsPubkeyHex: String(repeating: "cd", count: 48),
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: nil,
            variant: .tyranny(body: "look at this"),
            attachment: attachment
        )
    }

    func test_payload_withAttachment_roundTrips() throws {
        let payload = makePayload(attachment: sampleAttachment())
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.attachment?.sha256, payload.attachment?.sha256)
        XCTAssertEqual(decoded.attachment?.encKey, Data(repeating: 0x11, count: 32))

        // snake_case wire keys.
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"attachment\""))
        XCTAssertTrue(json.contains("\"enc_key\""))
        XCTAssertTrue(json.contains("\"byte_size\""))
        XCTAssertTrue(json.contains("\"mime_type\""))
    }

    func test_payload_withoutAttachment_isNil() throws {
        let payload = makePayload(attachment: nil)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: data)
        XCTAssertNil(decoded.attachment)
    }

    /// Back-compat: a payload minted by an older sender (no `attachment`
    /// key at all) must decode to `nil`, not throw.
    func test_payload_legacyWithoutAttachmentKey_decodesToNil() throws {
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
        XCTAssertNil(decoded.attachment)
        XCTAssertEqual(decoded.variant.body, "hi")
    }
}
