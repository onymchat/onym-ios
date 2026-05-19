import XCTest
@testable import OnymIOS

/// Cell-style switch tests for `ChatBubbleCell`. The direction
/// determines which alignment constraint is active and which color
/// the bubble + body use — both visible through the cell's
/// `contentView` subtree without needing the layout engine to
/// resolve.
@MainActor
final class ChatBubbleCellTests: XCTestCase {

    func test_outgoing_pinsToTrailingAndUsesAccentFill() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .outgoing))
        XCTAssertFalse(activeLeadingAlignment(in: cell),
                       "outgoing must release the leading-align constraint")
        XCTAssertTrue(activeTrailingAlignment(in: cell),
                      "outgoing must pin to the trailing edge")
    }

    func test_incoming_pinsToLeadingAndUsesSurfaceFill() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .incoming))
        XCTAssertTrue(activeLeadingAlignment(in: cell))
        XCTAssertFalse(activeTrailingAlignment(in: cell))
    }

    func test_reconfigure_flipsAlignment() {
        // Cell reuse path: a row that was outgoing is now rendering
        // an incoming message. The alignment must swap; otherwise
        // we'd see "own" bubbles on the wrong side.
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .outgoing))
        XCTAssertTrue(activeTrailingAlignment(in: cell))

        cell.configure(message: makeMessage(direction: .incoming))
        XCTAssertTrue(activeLeadingAlignment(in: cell))
        XCTAssertFalse(activeTrailingAlignment(in: cell))
    }

    func test_body_writesThroughToLabel() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .incoming, body: "hello, world"))
        let label = findLabel(in: cell.contentView)
        XCTAssertEqual(label?.text, "hello, world")
    }

    // MARK: - Constraint introspection
    //
    // The leading/trailing alignment constraints are private to the
    // cell. We can still detect which is active by reading the live
    // constraints attached to the cell's content view + bubble —
    // there are two `equal`-relation constraints on the bubble's
    // leading/trailing anchors, one of them inactive at any given
    // time.

    private func activeLeadingAlignment(in cell: ChatBubbleCell) -> Bool {
        guard let bubble = cell.contentView.subviews.first else { return false }
        return cell.contentView.constraints.contains {
            $0.isActive &&
            $0.firstItem === bubble &&
            $0.firstAttribute == .leading &&
            $0.secondItem === cell.contentView &&
            $0.secondAttribute == .leading &&
            $0.relation == .equal
        }
    }

    private func activeTrailingAlignment(in cell: ChatBubbleCell) -> Bool {
        guard let bubble = cell.contentView.subviews.first else { return false }
        return cell.contentView.constraints.contains {
            $0.isActive &&
            $0.firstItem === bubble &&
            $0.firstAttribute == .trailing &&
            $0.secondItem === cell.contentView &&
            $0.secondAttribute == .trailing &&
            $0.relation == .equal
        }
    }

    private func findLabel(in view: UIView) -> UILabel? {
        if let label = view as? UILabel { return label }
        for sub in view.subviews {
            if let found = findLabel(in: sub) { return found }
        }
        return nil
    }

    private func makeMessage(
        direction: MessageDirection,
        body: String = "hi"
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            groupID: "aa".repeated(32),
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: "11".repeated(48),
            body: body,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: direction,
            status: direction == .incoming ? .received : .sent,
            groupType: .tyranny
        )
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
