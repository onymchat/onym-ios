import XCTest
@testable import OnymIOS

/// Wire-format pin for `MemberProfile`. The struct rides inside two
/// other payloads (`GroupInvitationPayload.memberProfiles` and as a
/// stored value in `ChatGroup.memberProfiles`), so the shape needs
/// independent coverage — a regression here breaks both transport
/// and persistence at once.
final class MemberProfileTests: XCTestCase {

    func test_roundtrip_preservesAllFields() throws {
        let original = MemberProfile(
            alias: "Bob",
            inboxPublicKey: Data(repeating: 0xAA, count: 32),
            sendingPubkey: Data(repeating: 0xEE, count: 32)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemberProfile.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.sendingPubkey, Data(repeating: 0xEE, count: 32))
    }

    func test_wireFormat_snakeCaseKeys() throws {
        let payload = MemberProfile(
            alias: "x",
            inboxPublicKey: Data(repeating: 0, count: 32),
            sendingPubkey: Data(repeating: 0, count: 32)
        )
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["sending_pubkey"],
                        "wire key must match Android parity")
        XCTAssertNotNil(obj?["inbox_public_key"])
        XCTAssertNotNil(obj?["alias"])
    }

    // MARK: - Decode validation

    func test_decoder_rejectsWrongSizedSendingPubkey() throws {
        // A wrong-sized key on the wire would become a bogus
        // verification key for PR 4. Reject at decode.
        let inbox = Data(repeating: 0, count: 32).base64EncodedString()
        let badSending = Data(repeating: 0, count: 31).base64EncodedString()
        let json = #"""
        {"alias":"x","inbox_public_key":"\#(inbox)","sending_pubkey":"\#(badSending)"}
        """#
        let bytes = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MemberProfile.self, from: bytes)) { error in
            XCTAssertTrue(error is MemberProfileError)
        }
    }

    func test_decoder_rejectsWrongSizedInboxPublicKey() throws {
        let badInbox = Data(repeating: 0, count: 31).base64EncodedString()
        let sending = Data(repeating: 0, count: 32).base64EncodedString()
        let json = #"""
        {"alias":"x","inbox_public_key":"\#(badInbox)","sending_pubkey":"\#(sending)"}
        """#
        let bytes = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MemberProfile.self, from: bytes)) { error in
            XCTAssertTrue(error is MemberProfileError)
        }
    }

    func test_decoder_rejectsMissingSendingPubkey() throws {
        // Hard cutover — no `nil` migration window. Wire shapes
        // without `sending_pubkey` must fail loudly.
        let inbox = Data(repeating: 0, count: 32).base64EncodedString()
        let json = #"""
        {"alias":"x","inbox_public_key":"\#(inbox)"}
        """#
        let bytes = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MemberProfile.self, from: bytes))
    }
}
