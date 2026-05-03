import XCTest
@testable import OnymIOS

final class ChatGroupTests: XCTestCase {

    func test_groupIDData_roundtripsThroughHex() {
        let raw = Data(repeating: 0xAB, count: 32)
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        let group = makeGroup(id: hex)
        XCTAssertEqual(group.groupIDData, raw)
        XCTAssertEqual(group.groupIDData.count, 32)
    }

    func test_groupIDData_handlesShortHex() {
        let group = makeGroup(id: "abcd")
        XCTAssertEqual(group.groupIDData, Data([0xAB, 0xCD]))
    }

    func test_groupIDData_isLowercaseInsensitive() {
        let group = makeGroup(id: "AbCd")
        XCTAssertEqual(group.groupIDData, Data([0xAB, 0xCD]))
    }

    private func makeGroup(id: String) -> ChatGroup {
        ChatGroup(
            id: id,
            ownerIdentityID: IdentityID(),
            name: "test",
            groupSecret: Data(repeating: 0, count: 32),
            createdAt: Date(timeIntervalSince1970: 0),
            members: [],
            epoch: 0,
            salt: Data(repeating: 0, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            isPublishedOnChain: false
        )
    }
}
