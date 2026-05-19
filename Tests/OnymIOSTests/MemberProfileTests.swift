import XCTest
@testable import OnymIOS

/// Wire-format pin for `MemberProfile`. The struct rides inside two
/// other payloads (`GroupInvitationPayload.memberProfiles` and as a
/// stored value in `ChatGroup.memberProfiles`), so the shape needs
/// independent coverage — a regression here breaks both transport
/// and persistence at once.
final class MemberProfileTests: XCTestCase {

    func test_roundtrip_withSendingPubkey_preservesAllFields() throws {
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

    func test_roundtrip_withoutSendingPubkey_decodesAsNil() throws {
        let original = MemberProfile(
            alias: "Bob",
            inboxPublicKey: Data(repeating: 0xAA, count: 32)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemberProfile.self, from: encoded)
        XCTAssertNil(decoded.sendingPubkey)
        XCTAssertEqual(decoded, original)
    }

    func test_wireFormat_snakeCaseKey() throws {
        let payload = MemberProfile(
            alias: "x",
            inboxPublicKey: Data(repeating: 0, count: 32),
            sendingPubkey: Data(repeating: 0, count: 32)
        )
        let encoded = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(obj?["sending_pubkey"],
                        "PR 3 wire key must match Android parity")
        XCTAssertNotNil(obj?["inbox_public_key"])
        XCTAssertNotNil(obj?["alias"])
    }

    func test_decoder_acceptsLegacyProfileWithoutSendingPubkey() throws {
        // Pre-PR-3 senders (and any member who joined before PR 3
        // shipped) won't carry `sending_pubkey`. Receivers must
        // decode those into a profile with `sendingPubkey == nil` so
        // the group still materializes; PR 4's dispatcher then falls
        // back to BLS-claim trust for that member.
        let inbox = Data(repeating: 0, count: 32).base64EncodedString()
        let legacy = #"""
        {"alias":"Bob","inbox_public_key":"\#(inbox)"}
        """#
        let bytes = legacy.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MemberProfile.self, from: bytes)
        XCTAssertNil(decoded.sendingPubkey)
        XCTAssertEqual(decoded.alias, "Bob")
    }
}
