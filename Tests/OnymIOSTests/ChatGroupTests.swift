import XCTest
@testable import OnymIOS
import OnymIdentity
import OnymGroup

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

    // MARK: - linkableRules

    func test_linkableRules_areTheCanonicalTextAJoinerWillSign() {
        let group = makeGroup(id: "abcd", invitationMessage: "  Be kind.\n")
        XCTAssertEqual(
            group.linkableRules, "Be kind.",
            "the link carries the same form the signature covers"
        )
    }

    func test_linkableRules_areNilForAGroupThatAsksNothing() {
        XCTAssertNil(makeGroup(id: "abcd", invitationMessage: nil).linkableRules)
        XCTAssertNil(
            makeGroup(id: "abcd", invitationMessage: "   ").linkableRules,
            "blank rules are no rules, not an empty thing to agree to"
        )
    }

    func test_linkableRules_omitTextTooLongForALink_ratherThanBlockingTheShare() {
        // The field was documented as "any length" before the cap, so a
        // group created by an earlier build can hold more than an
        // invite accepts. Omitted rather than truncated: an abridged
        // text is the one option that produces a wrong answer instead
        // of a missing one, since joiners would sign it and every
        // signature would then fail against the founder's full copy.
        let long = String(repeating: "a", count: GroupRules.maxBytes + 1)
        let group = makeGroup(id: "abcd", invitationMessage: long)

        XCTAssertNil(group.linkableRules)
        XCTAssertNoThrow(
            try IntroCapability(
                introPublicKey: Data(repeating: 0x44, count: 32),
                groupId: Data(repeating: 0x11, count: 32),
                groupName: group.name,
                rules: group.linkableRules
            ),
            "a legacy group must still be shareable"
        )
    }

    private func makeGroup(id: String, invitationMessage: String? = nil) -> ChatGroup {
        ChatGroup(
            id: id,
            ownerIdentityID: IdentityID(),
            name: "test",
            groupSecret: Data(repeating: 0, count: 32),
            createdAt: Date(timeIntervalSince1970: 0),
            members: [],
            memberProfiles: [:],
            epoch: 0,
            salt: Data(repeating: 0, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: false,
            invitationMessage: invitationMessage
        )
    }
}
