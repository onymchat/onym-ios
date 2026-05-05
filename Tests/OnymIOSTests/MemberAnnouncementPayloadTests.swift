import XCTest
@testable import OnymIOS

/// Wire-format pin for `MemberAnnouncementPayload`. Authored on iOS
/// first; onym-android will mirror. Cross-platform parity is checked
/// via the snake_case key spelling assertions — Swift `JSONEncoder`
/// + Kotlin `kotlinx.serialization.Json` both serialize `Data` /
/// `ByteArray` to standard base64 with padding by default.
final class MemberAnnouncementPayloadTests: XCTestCase {

    // MARK: - Round-trip

    func test_roundtrip_preservesAllFields() throws {
        let member = try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: Data(repeating: 0x11, count: 48),
            inboxPub: Data(repeating: 0x33, count: 32),
            alias: "Bob"
        )
        let original = try MemberAnnouncementPayload(
            version: 1,
            groupId: Data(repeating: 0x42, count: 32),
            newMember: member,
            adminAlias: "Alice"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            MemberAnnouncementPayload.self,
            from: encoded
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Wire shape

    func test_snake_case_keys_match_android_parity() throws {
        let member = try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: Data(repeating: 0, count: 48),
            inboxPub: Data(repeating: 0, count: 32),
            alias: "Bob"
        )
        let payload = try MemberAnnouncementPayload(
            version: 1,
            groupId: Data(repeating: 0, count: 32),
            newMember: member,
            adminAlias: "Alice"
        )
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["version"])
        XCTAssertNotNil(obj?["group_id"])
        XCTAssertNotNil(obj?["new_member"])
        XCTAssertNotNil(obj?["admin_alias"])
        XCTAssertEqual(obj?["admin_alias"] as? String, "Alice")
        let memberObj = obj?["new_member"] as? [String: Any]
        XCTAssertNotNil(memberObj?["bls_pub"])
        XCTAssertNotNil(memberObj?["inbox_pub"])
        XCTAssertNotNil(memberObj?["alias"])
        XCTAssertNil(memberObj?["leaf_hash"],
                     "leaf_hash is intentionally absent in v1")
        XCTAssertEqual(memberObj?["alias"] as? String, "Bob")
    }

    // MARK: - Constructor validation

    func test_constructor_rejectsWrongSizedGroupId() {
        let member = try! MemberAnnouncementPayload.AnnouncedMember(
            blsPub: Data(repeating: 0, count: 48),
            inboxPub: Data(repeating: 0, count: 32),
            alias: "x"
        )
        XCTAssertThrowsError(try MemberAnnouncementPayload(
            version: 1,
            groupId: Data(repeating: 0, count: 31),
            newMember: member,
            adminAlias: "y"
        )) { error in
            XCTAssertTrue(error is MemberAnnouncementPayloadError)
        }
    }

    func test_announcedMember_constructor_rejectsWrongSizedBlsPub() {
        XCTAssertThrowsError(try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: Data(repeating: 0, count: 47),
            inboxPub: Data(repeating: 0, count: 32),
            alias: "x"
        )) { error in
            XCTAssertTrue(error is MemberAnnouncementPayloadError)
        }
    }

    func test_announcedMember_constructor_rejectsWrongSizedInboxPub() {
        XCTAssertThrowsError(try MemberAnnouncementPayload.AnnouncedMember(
            blsPub: Data(repeating: 0, count: 48),
            inboxPub: Data(repeating: 0, count: 31),
            alias: "x"
        )) { error in
            XCTAssertTrue(error is MemberAnnouncementPayloadError)
        }
    }

    // MARK: - Decoder validation

    func test_decoder_rejectsWrongSizedGroupId() {
        let bad = #"""
        {"version":1,"group_id":"AAA=","new_member":{"bls_pub":"\#(base64Zeros(48))","inbox_pub":"\#(base64Zeros(32))","alias":"x"},"admin_alias":"y"}
        """#
        let bytes = bad.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(MemberAnnouncementPayload.self, from: bytes)
        ) { error in
            XCTAssertTrue(error is MemberAnnouncementPayloadError)
        }
    }

    func test_decoder_rejectsWrongSizedBlsPub() {
        let bad = #"""
        {"version":1,"group_id":"\#(base64Zeros(32))","new_member":{"bls_pub":"AAA=","inbox_pub":"\#(base64Zeros(32))","alias":"x"},"admin_alias":"y"}
        """#
        let bytes = bad.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(MemberAnnouncementPayload.self, from: bytes)
        ) { error in
            XCTAssertTrue(error is MemberAnnouncementPayloadError)
        }
    }

    func test_decoder_ignoresUnknownLeafHashField_forForwardCompat() throws {
        // V2 receivers may add `leaf_hash`; V1 receivers MUST decode
        // payloads carrying it, ignoring the unknown field.
        let v2Shape = #"""
        {"version":2,"group_id":"\#(base64Zeros(32))","new_member":{"bls_pub":"\#(base64Zeros(48))","leaf_hash":"\#(base64Zeros(32))","inbox_pub":"\#(base64Zeros(32))","alias":"x"},"admin_alias":"y"}
        """#
        let bytes = v2Shape.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            MemberAnnouncementPayload.self,
            from: bytes
        )
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.newMember.alias, "x")
    }

    // MARK: - Helpers

    private func base64Zeros(_ count: Int) -> String {
        Data(repeating: 0, count: count).base64EncodedString()
    }
}
