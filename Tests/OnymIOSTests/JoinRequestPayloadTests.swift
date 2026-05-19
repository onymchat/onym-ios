import XCTest
@testable import OnymIOS

/// Wire-format pin for `JoinRequestPayload`. Mirrors
/// `JoinRequestPayloadTest.kt`. Cross-platform parity is checked
/// via the snake_case key spelling assertions — Swift `JSONEncoder`
/// + Kotlin `kotlinx.serialization.Json` both serialize `Data` /
/// `ByteArray` to standard base64 with padding by default.
final class JoinRequestPayloadTests: XCTestCase {

    func test_roundtrip_preservesAllFields() throws {
        let original = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: Data(repeating: 0xBB, count: 48),
            joinerLeafHash: Data(repeating: 0xCC, count: 32),
            joinerSendingPublicKey: Data(repeating: 0xEE, count: 32),
            joinerDisplayLabel: "Bob",
            groupId: Data(repeating: 0x42, count: 32)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JoinRequestPayload.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.joinerSendingPublicKey, Data(repeating: 0xEE, count: 32))
    }

    func test_wire_carries_joiner_sending_pub() throws {
        let payload = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0, count: 32),
            joinerBlsPublicKey: Data(repeating: 0, count: 48),
            joinerLeafHash: Data(repeating: 0, count: 32),
            joinerSendingPublicKey: Data(repeating: 0xEE, count: 32),
            joinerDisplayLabel: "x",
            groupId: Data(repeating: 0, count: 32)
        )
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["joiner_sending_pub"],
                        "PR 3 wire key must match Android parity")
    }

    func test_decoder_rejectsRequestWithoutSendingPub() throws {
        // `joiner_sending_pub` is required — receivers must reject
        // any request that omits it. (No real users on the join
        // path yet, so we ship without a migration window.)
        let inbox = Data(repeating: 0, count: 32).base64EncodedString()
        let gid = Data(repeating: 0, count: 32).base64EncodedString()
        let bls = Data(repeating: 0, count: 48).base64EncodedString()
        let json = #"""
        {"joiner_inbox_pub":"\#(inbox)","joiner_bls_pub":"\#(bls)","joiner_display_label":"Bob","group_id":"\#(gid)"}
        """#
        let bytes = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(JoinRequestPayload.self, from: bytes))
    }

    func test_constructor_rejectsWrongSizedSendingPubkey() {
        XCTAssertThrowsError(try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: Data(repeating: 0, count: 31),
            joinerDisplayLabel: "x",
            groupId: Data(repeating: 0, count: 32)
        )) { error in
            XCTAssertTrue(error is JoinRequestPayloadError)
        }
    }

    func test_snake_case_keys_match_android_parity() throws {
        // Cross-platform interop pin — Android uses snake_case
        // SerialName annotations; Swift must match for the
        // sealed-then-decoded round-trip to work.
        let payload = try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0, count: 32),
            joinerBlsPublicKey: Data(repeating: 0, count: 48),
            joinerLeafHash: Data(repeating: 0, count: 32),
            joinerSendingPublicKey: Data(repeating: 0, count: 32),
            joinerDisplayLabel: "Bob",
            groupId: Data(repeating: 0, count: 32)
        )
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["joiner_inbox_pub"])
        XCTAssertNotNil(obj?["joiner_bls_pub"])
        XCTAssertNotNil(obj?["joiner_display_label"])
        XCTAssertNotNil(obj?["group_id"])
        XCTAssertEqual(obj?["joiner_display_label"] as? String, "Bob")
    }

    func test_constructor_rejectsWrongSizedKeys() {
        XCTAssertThrowsError(try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0, count: 31),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: Data(repeating: 0, count: 32),
            joinerDisplayLabel: "x",
            groupId: Data(repeating: 0, count: 32)
        )) { error in
            XCTAssertTrue(error is JoinRequestPayloadError)
        }
        XCTAssertThrowsError(try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0, count: 32),
            joinerBlsPublicKey: nil,
            joinerLeafHash: nil,
            joinerSendingPublicKey: Data(repeating: 0, count: 32),
            joinerDisplayLabel: "x",
            groupId: Data(repeating: 0, count: 33)
        )) { error in
            XCTAssertTrue(error is JoinRequestPayloadError)
        }
        XCTAssertThrowsError(try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0, count: 32),
            joinerBlsPublicKey: Data(repeating: 0, count: 47),
            joinerLeafHash: nil,
            joinerSendingPublicKey: Data(repeating: 0, count: 32),
            joinerDisplayLabel: "x",
            groupId: Data(repeating: 0, count: 32)
        )) { error in
            XCTAssertTrue(error is JoinRequestPayloadError)
        }
        // Wrong-sized leaf hash also rejected.
        XCTAssertThrowsError(try JoinRequestPayload(
            joinerInboxPublicKey: Data(repeating: 0, count: 32),
            joinerBlsPublicKey: Data(repeating: 0, count: 48),
            joinerLeafHash: Data(repeating: 0, count: 31),
            joinerSendingPublicKey: Data(repeating: 0, count: 32),
            joinerDisplayLabel: "x",
            groupId: Data(repeating: 0, count: 32)
        )) { error in
            XCTAssertTrue(error is JoinRequestPayloadError)
        }
    }

    func test_decoder_rejectsWrongSizedKeys() {
        let payloadJSON = #"""
        {"joiner_inbox_pub":"AAA=","joiner_sending_pub":"AAA=","joiner_display_label":"Bob","group_id":"AAA="}
        """#
        let bytes = payloadJSON.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(JoinRequestPayload.self, from: bytes)) { error in
            XCTAssertTrue(error is JoinRequestPayloadError)
        }
    }

    func test_decoder_acceptsPayloadWithoutBlsPub() throws {
        // `joiner_bls_pub` stays optional — a request without it
        // round-trips into `joinerBlsPublicKey == nil` so the
        // approver can still ship the invitation back (only the
        // local roster update is skipped).
        let inbox = Data(repeating: 0, count: 32).base64EncodedString()
        let gid = Data(repeating: 0, count: 32).base64EncodedString()
        let sending = Data(repeating: 0, count: 32).base64EncodedString()
        let json = #"""
        {"joiner_inbox_pub":"\#(inbox)","joiner_sending_pub":"\#(sending)","joiner_display_label":"Bob","group_id":"\#(gid)"}
        """#
        let bytes = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(JoinRequestPayload.self, from: bytes)
        XCTAssertNil(decoded.joinerBlsPublicKey)
        XCTAssertEqual(decoded.joinerDisplayLabel, "Bob")
    }
}
