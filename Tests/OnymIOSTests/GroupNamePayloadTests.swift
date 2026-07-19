import XCTest
@testable import OnymIOS

/// Wire-format pin for `GroupNamePayload` (admin group rename). Its
/// distinct `name_*` keys keep the dispatcher's structural decode from
/// confusing it with any other payload — asserted alongside the basic
/// round-trip and both directions of the chat-message collision.
final class GroupNamePayloadTests: XCTestCase {

    func test_roundtrip_preservesName() throws {
        let original = makePayload(name: "Maple Garden")
        let decoded = try JSONDecoder().decode(
            GroupNamePayload.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.name, "Maple Garden")
    }

    func test_wireKeys_useNamePrefix() throws {
        let encoded = try JSONEncoder().encode(makePayload(name: "G"))
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["name_version"])
        XCTAssertNotNil(obj?["name_group_id"])
        XCTAssertNotNil(obj?["name_sender_bls_hex"])
        XCTAssertNotNil(obj?["name_sent_at_millis"])
        XCTAssertNotNil(obj?["name_value"])
    }

    // MARK: - Anti-collision

    func test_chatMessage_doesNotDecodeAsName() throws {
        let chat = ChatMessagePayload(
            version: 1,
            messageID: UUID(),
            groupID: Data(repeating: 0x42, count: 32),
            senderBlsPubkeyHex: "aa".repeated(48),
            sentAtMillis: 1_700_000_000_000,
            replyToMessageID: nil,
            variant: .tyranny(body: "hello")
        )
        let bytes = try JSONEncoder().encode(chat)
        XCTAssertThrowsError(
            try JSONDecoder().decode(GroupNamePayload.self, from: bytes),
            "a chat message lacks name_* keys and must not decode as a rename payload"
        )
    }

    func test_name_doesNotDecodeAsAvatarOrChat() throws {
        let bytes = try JSONEncoder().encode(makePayload(name: "G"))
        XCTAssertThrowsError(
            try JSONDecoder().decode(GroupAvatarPayload.self, from: bytes),
            "a rename payload lacks avatar_* keys and must not decode as an avatar payload"
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ChatMessagePayload.self, from: bytes),
            "a rename payload lacks message_id / variant and must not decode as a chat message"
        )
    }

    private func makePayload(name: String) -> GroupNamePayload {
        GroupNamePayload(
            version: 1,
            groupID: Data(repeating: 0x42, count: 32),
            senderBlsPubkeyHex: "aa".repeated(48),
            sentAtMillis: 1_700_000_000_000,
            name: name
        )
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
