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
}
