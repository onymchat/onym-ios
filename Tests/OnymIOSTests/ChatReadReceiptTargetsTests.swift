import XCTest
@testable import OnymIOS
@testable import OnymChatsUI
import OnymChain
import OnymIdentity
import OnymChatsCore

/// System notices are stored `.incoming` with a real member's BLS hex,
/// which put them on the read-receipt path by accident. These pin the
/// exclusion: a notice must never cause outbound relay traffic.
final class ChatReadReceiptTargetsTests: XCTestCase {

    private let joinerHex = String(repeating: "22", count: 48)
    private let ownHex = String(repeating: "33", count: 48)

    func test_systemNotice_neverOwesAReadReceipt() {
        let notice = makeMessage(
            senderHex: joinerHex,
            systemEvent: .memberJoined(alias: "Alice")
        )

        let targets = ChatReadReceiptTargets.unacked(in: [notice], alreadyAcked: [])

        XCTAssertTrue(targets.isEmpty,
                      "a joined notice must not ship a receipt to the joiner")
    }

    /// "You joined" carries this device's own BLS key, which is in
    /// `memberProfiles` — so without the exclusion the app would address
    /// a read receipt to itself.
    func test_youJoinedNotice_doesNotReceiptYourself() {
        let notice = makeMessage(
            senderHex: ownHex,
            systemEvent: .youJoined(groupName: "Book club")
        )

        let targets = ChatReadReceiptTargets.unacked(in: [notice], alreadyAcked: [])

        XCTAssertTrue(targets.isEmpty)
    }

    /// The exact regression: a brand-new group whose only content is the
    /// membership notices must emit nothing when opened.
    func test_threadOfOnlyNotices_emitsNothing() {
        let snapshot = [
            makeMessage(senderHex: ownHex, systemEvent: .youJoined(groupName: "Book club")),
            makeMessage(senderHex: joinerHex, systemEvent: .memberJoined(alias: "Alice"))
        ]

        XCTAssertTrue(ChatReadReceiptTargets.unacked(in: snapshot, alreadyAcked: []).isEmpty)
    }

    func test_realIncomingMessage_stillOwesAReceipt() {
        let message = makeMessage(senderHex: joinerHex, systemEvent: nil)

        let targets = ChatReadReceiptTargets.unacked(in: [message], alreadyAcked: [])

        XCTAssertEqual(targets[joinerHex], [message.id])
    }

    /// A notice sitting between real messages must not suppress them.
    func test_noticesAreSkippedWithoutDroppingRealMessages() {
        let real = makeMessage(senderHex: joinerHex, systemEvent: nil)
        let notice = makeMessage(
            senderHex: joinerHex,
            systemEvent: .memberJoined(alias: "Alice")
        )

        let targets = ChatReadReceiptTargets.unacked(in: [notice, real], alreadyAcked: [])

        XCTAssertEqual(targets[joinerHex], [real.id])
    }

    func test_outgoingAndAlreadyAcked_areExcluded() {
        let outgoing = makeMessage(
            senderHex: ownHex,
            systemEvent: nil,
            direction: .outgoing
        )
        let acked = makeMessage(senderHex: joinerHex, systemEvent: nil)

        let targets = ChatReadReceiptTargets.unacked(
            in: [outgoing, acked],
            alreadyAcked: [acked.id]
        )

        XCTAssertTrue(targets.isEmpty)
    }

    // MARK: - Helpers

    private func makeMessage(
        senderHex: String,
        systemEvent: ChatSystemEvent?,
        direction: MessageDirection = .incoming
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            groupID: String(repeating: "aa", count: 32),
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: senderHex,
            body: systemEvent == nil ? "hello" : "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: direction,
            status: direction == .incoming ? .received : .sent,
            replyToMessageID: nil,
            groupType: .tyranny,
            systemEvent: systemEvent
        )
    }
}
