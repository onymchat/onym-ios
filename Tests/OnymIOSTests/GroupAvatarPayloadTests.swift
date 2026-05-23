import XCTest
@testable import OnymIOS

/// Wire-format pin for `GroupAvatarPayload`. The load-bearing property
/// is that its distinct `avatar_*` keys keep the dispatcher's structural
/// decode from confusing it with a `ChatMessagePayload` (which shares
/// version / group_id / sender / timestamp) — so both directions of that
/// collision are asserted alongside the basic round-trip.
final class GroupAvatarPayloadTests: XCTestCase {

    func test_roundtrip_withAvatar_preservesBytes() throws {
        let original = makePayload(avatar: Data(repeating: 0x5A, count: 2048))
        let decoded = try JSONDecoder().decode(
            GroupAvatarPayload.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    func test_roundtrip_nilAvatar_isRemoval() throws {
        let original = makePayload(avatar: nil)
        let encoded = try JSONEncoder().encode(original)
        // nil avatar must not emit the key (encodeIfPresent).
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNil(obj?["avatar"])
        let decoded = try JSONDecoder().decode(GroupAvatarPayload.self, from: encoded)
        XCTAssertNil(decoded.avatar)
    }

    func test_wireKeys_useAvatarPrefix() throws {
        let encoded = try JSONEncoder().encode(makePayload(avatar: Data([0x01])))
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["avatar_version"])
        XCTAssertNotNil(obj?["avatar_group_id"])
        XCTAssertNotNil(obj?["avatar_sent_at_millis"])
    }

    // MARK: - Anti-collision with ChatMessagePayload

    func test_chatMessage_doesNotDecodeAsAvatar() throws {
        let chat = ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: Data(repeating: 0x42, count: 32),
            senderBlsPubkeyHex: "aa".repeated(48),
            sentAtMillis: 1_700_000_000_000,
            variant: .tyranny(body: "hello")
        )
        let bytes = try JSONEncoder().encode(chat)
        XCTAssertThrowsError(
            try JSONDecoder().decode(GroupAvatarPayload.self, from: bytes),
            "a chat message lacks avatar_* keys and must not decode as an avatar payload"
        )
    }

    func test_avatar_doesNotDecodeAsChatMessage() throws {
        let bytes = try JSONEncoder().encode(makePayload(avatar: Data([0x01, 0x02])))
        XCTAssertThrowsError(
            try JSONDecoder().decode(ChatMessagePayload.self, from: bytes),
            "an avatar payload lacks message_id / variant and must not decode as a chat message"
        )
    }

    // MARK: - Helpers

    private func makePayload(avatar: Data?) -> GroupAvatarPayload {
        GroupAvatarPayload(
            version: 1,
            groupID: Data(repeating: 0x42, count: 32),
            senderBlsPubkeyHex: "aa".repeated(48),
            sentAtMillis: 1_700_000_000_000,
            avatar: avatar
        )
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
