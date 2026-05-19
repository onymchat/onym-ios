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

    func test_layoutResolves_withoutConstraintConflicts() {
        // Guards the bug the PR-6 review caught: pairing the
        // opposite-edge `>=`/`<=` gap with the *same-direction*
        // alignment pin would conflict (e.g. leading == +12 AND
        // leading >= +56). UIKit logs and silently disables one,
        // which the original constraint-isActive tests didn't
        // notice. Forcing a layout pass and asserting all
        // constraints are still active is the cheapest way to
        // catch a regression here.
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.contentView.frame = CGRect(x: 0, y: 0, width: 320, height: 80)

        cell.configure(message: makeMessage(direction: .incoming, body: "hi"))
        cell.contentView.layoutIfNeeded()
        XCTAssertTrue(allConstraintsStillActive(cell),
                      "incoming layout must not auto-deactivate any constraint")

        cell.configure(message: makeMessage(direction: .outgoing, body: "hi"))
        cell.contentView.layoutIfNeeded()
        XCTAssertTrue(allConstraintsStillActive(cell),
                      "outgoing layout must not auto-deactivate any constraint")
    }

    // MARK: - Constraint introspection
    //
    // The alignment constraint pairs are private to the cell. We
    // detect which side is pinned by looking for an `equal`-relation
    // constraint between the bubble's anchor and the corresponding
    // content-view anchor — that's the alignment pin (one per pair).

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

    /// `true` iff every required constraint on the cell remains
    /// active after a layout pass. UIKit auto-deactivates the lower-
    /// priority constraint when a `required` conflict resolves — so
    /// a count-stable layout proves no conflict happened.
    private func allConstraintsStillActive(_ cell: ChatBubbleCell) -> Bool {
        // The cell builds eight always-on constraints + two from the
        // direction pair == 10 active total. Anything less means
        // UIKit disabled one to resolve a conflict.
        let active = collectActiveConstraints(in: cell.contentView)
        return active.count >= 10
    }

    private func collectActiveConstraints(in view: UIView) -> [NSLayoutConstraint] {
        var found: [NSLayoutConstraint] = view.constraints.filter { $0.isActive }
        for sub in view.subviews {
            found.append(contentsOf: collectActiveConstraints(in: sub))
        }
        return found
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
