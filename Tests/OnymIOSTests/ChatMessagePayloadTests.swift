import XCTest
@testable import OnymIOS

/// Wire-format pin for `ChatMessagePayload`. The struct is the
/// plaintext that gets sealed in the same envelope as
/// `GroupInvitationPayload`, so the wire format is part of the
/// cross-platform contract — these tests lock the field spelling and
/// the variant discriminator.
final class ChatMessagePayloadTests: XCTestCase {

    // MARK: - Round-trip

    func test_roundtrip_tyranny_preservesAllFields() throws {
        let original = makePayload(body: "hello, world")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.variant.body, "hello, world")
    }

    func test_roundtrip_emptyBody_succeeds() throws {
        // Empty body is a valid wire shape — validation lives at the
        // send/receive boundary, not in the data type.
        let original = makePayload(body: "")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: encoded)
        XCTAssertEqual(decoded.variant.body, "")
    }

    func test_roundtrip_unicodeBody_preservesBytes() throws {
        // We don't render emoji in v1, but the payload is content-
        // agnostic — locking this guards against accidentally
        // stripping non-ASCII at the encoder layer.
        let original = makePayload(body: "héllo 🌍 こんにちは")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: encoded)
        XCTAssertEqual(decoded.variant.body, "héllo 🌍 こんにちは")
    }

    // MARK: - Reply reference

    func test_roundtrip_replyRef_preservesTargetID() throws {
        let target = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let original = makePayload(body: "agreed", replyToMessageID: target)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: encoded)
        XCTAssertEqual(decoded.replyToMessageID, target)
        XCTAssertEqual(decoded, original)
    }

    func test_wireFormat_replyKeyIsSnakeCase() throws {
        let target = UUID()
        let encoded = try JSONEncoder().encode(makePayload(body: "hi", replyToMessageID: target))
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(obj?["reply_to_message_id"] as? String, target.uuidString)
    }

    func test_wireFormat_noReply_omitsKey() throws {
        // A non-reply message should encode `null` (or omit) — never a
        // bogus UUID. `JSONEncoder` writes `null` for a nil Optional.
        let encoded = try JSONEncoder().encode(makePayload(body: "hi"))
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNil(obj?["reply_to_message_id"] as? String,
                     "a non-reply message must not carry a reply target")
    }

    func test_decode_missingReplyKey_isNil() throws {
        // Backward compat: a payload from an older sender (pre-replies)
        // has no `reply_to_message_id` — it must decode to nil, not throw.
        let json = #"""
        {
          "version": 1,
          "message_id": "11111111-1111-1111-1111-111111111111",
          "group_id": "QkJC",
          "sender_bls_pubkey_hex": "ab",
          "sent_at_millis": 0,
          "variant": { "kind": "tyranny", "body": "hi" }
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: json)
        XCTAssertNil(decoded.replyToMessageID)
    }

    // MARK: - Wire format

    func test_wireFormat_snakeCaseKeys() throws {
        let payload = makePayload(body: "hi")
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["message_id"],
                        "snake_case key 'message_id' must match Android parity")
        XCTAssertNotNil(obj?["group_id"])
        XCTAssertNotNil(obj?["sender_bls_pubkey_hex"])
        XCTAssertNotNil(obj?["sent_at_millis"])
        XCTAssertNotNil(obj?["variant"])
    }

    func test_wireFormat_variantDiscriminatorMatchesSEPGroupType() throws {
        // The variant's `kind` field must be the same lowercase string
        // the relayer + contracts use — `SEPGroupType.tyranny.rawValue`
        // is the single source of truth.
        let payload = makePayload(body: "hi")
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let variant = obj?["variant"] as? [String: Any]
        XCTAssertEqual(variant?["kind"] as? String, SEPGroupType.tyranny.rawValue)
        XCTAssertEqual(variant?["body"] as? String, "hi")
    }

    // MARK: - Decode failures

    func test_decode_unknownVariantKind_throws() throws {
        let json = #"""
        {
          "version": 1,
          "message_id": "11111111-1111-1111-1111-111111111111",
          "group_id": "QkJC",
          "sender_bls_pubkey_hex": "ab",
          "sent_at_millis": 0,
          "variant": { "kind": "martian", "body": "x" }
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ChatMessagePayload.self, from: json))
    }

    func test_decode_unsupportedVariantKind_throws() throws {
        // `oneonone` is a known SEPGroupType but chat doesn't support
        // it yet — decoding must throw, not silently coerce.
        let json = #"""
        {
          "version": 1,
          "message_id": "11111111-1111-1111-1111-111111111111",
          "group_id": "QkJC",
          "sender_bls_pubkey_hex": "ab",
          "sent_at_millis": 0,
          "variant": { "kind": "oneonone", "body": "x" }
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ChatMessagePayload.self, from: json))
    }

    func test_decode_missingRequiredField_throws() throws {
        // `message_id` is required — drop it and decode must throw.
        let json = #"""
        {
          "version": 1,
          "group_id": "QkJC",
          "sender_bls_pubkey_hex": "ab",
          "sent_at_millis": 0,
          "variant": { "kind": "tyranny", "body": "hi" }
        }
        """#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ChatMessagePayload.self, from: json))
    }

    func test_decode_extraField_isIgnored() throws {
        // Forward-compat: a v1 receiver decoding payload from a
        // sender that added an optional field must succeed.
        let json = #"""
        {
          "version": 1,
          "message_id": "11111111-1111-1111-1111-111111111111",
          "group_id": "QkJC",
          "sender_bls_pubkey_hex": "ab",
          "sent_at_millis": 0,
          "variant": { "kind": "tyranny", "body": "hi" },
          "future_field_for_v2": "ignored"
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatMessagePayload.self, from: json)
        XCTAssertEqual(decoded.variant.body, "hi")
    }

    // MARK: - Helpers

    private func makePayload(
        body: String,
        replyToMessageID: UUID? = nil
    ) -> ChatMessagePayload {
        ChatMessagePayload(
            version: 1,
            messageID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            groupID: Data(repeating: 0x42, count: 32),
            senderBlsPubkeyHex: String(repeating: "ab", count: 48),
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: replyToMessageID,
            variant: .tyranny(body: body)
        )
    }
}
