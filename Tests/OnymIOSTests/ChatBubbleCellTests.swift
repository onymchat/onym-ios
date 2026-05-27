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

    // MARK: - Sender name header

    func test_senderHeader_shownWhenRequested_writesNameThrough() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(
            message: makeMessage(direction: .incoming),
            sender: ChatSenderDisplay(name: "Alice", accent: .purple, showNameHeader: true)
        )
        let header = senderHeader(in: cell)
        XCTAssertFalse(header.isHidden, "header must be visible when showNameHeader is true")
        XCTAssertEqual(header.text, "Alice")
    }

    func test_senderHeader_hiddenWhenNotRequested() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(
            message: makeMessage(direction: .incoming),
            sender: ChatSenderDisplay(name: "Alice", accent: .purple, showNameHeader: false)
        )
        XCTAssertTrue(senderHeader(in: cell).isHidden,
                      "mid-run / suppressed messages must not show a header")
    }

    func test_senderHeader_droppedOnReuse() {
        // Cell reuse: a row that showed a header is reused for a
        // mid-run message. The header must clear, or a grouped
        // message would carry a stale name.
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(
            message: makeMessage(direction: .incoming),
            sender: ChatSenderDisplay(name: "Alice", accent: .purple, showNameHeader: true)
        )
        XCTAssertFalse(senderHeader(in: cell).isHidden)

        cell.configure(
            message: makeMessage(direction: .incoming),
            sender: ChatSenderDisplay(name: "Alice", accent: .purple, showNameHeader: false)
        )
        XCTAssertTrue(senderHeader(in: cell).isHidden,
                      "reused cell must drop the previously-shown header")
    }

    func test_defaultSender_showsNoHeader() {
        // The `.unknown` default (older call sites / missing display)
        // must not surface a header.
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .incoming))
        XCTAssertTrue(senderHeader(in: cell).isHidden)
    }

    private func senderHeader(in cell: ChatBubbleCell) -> UILabel {
        guard let label = find(in: cell.contentView, identifier: "chat.bubble.sender")
                as? UILabel else {
            fatalError("sender header not found")
        }
        return label
    }

    // MARK: - Status indicator (PR 9)

    func test_outgoingPending_showsClockIcon() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .outgoing, status: .pending))
        let icon = statusIcon(in: cell)
        XCTAssertFalse(icon.isHidden)
        // SF Symbols comparison via `accessibilityLabel` since the
        // UIImage isn't easily equatable across symbol-config
        // variations.
        XCTAssertEqual(icon.accessibilityLabel, "Sending")
    }

    func test_outgoingSent_showsCheckIcon() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .outgoing, status: .sent))
        let icon = statusIcon(in: cell)
        XCTAssertFalse(icon.isHidden)
        XCTAssertEqual(icon.accessibilityLabel, "Sent")
    }

    func test_outgoingFailed_showsExclamationInRed() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .outgoing, status: .failed))
        let icon = statusIcon(in: cell)
        XCTAssertFalse(icon.isHidden)
        XCTAssertEqual(icon.accessibilityLabel, "Failed — tap to retry")
    }

    func test_incoming_hidesStatusIndicator() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        cell.configure(message: makeMessage(direction: .incoming, status: .received))
        XCTAssertTrue(statusIcon(in: cell).isHidden,
                      "incoming rows must hide the status indicator")
    }

    func test_reconfigure_flipsStatusIcon() {
        // Cell reuse path: a row that was .pending must update to
        // .sent when its message is reconfigured against an updated
        // ChatMessage. Without this, the diffable data source's
        // `reconfigureItems` path would update messagesByID but the
        // glyph would stay stale.
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        let id = UUID()
        cell.configure(message: makeMessage(id: id, direction: .outgoing, status: .pending))
        XCTAssertEqual(statusIcon(in: cell).accessibilityLabel, "Sending")

        cell.configure(message: makeMessage(id: id, direction: .outgoing, status: .sent))
        XCTAssertEqual(statusIcon(in: cell).accessibilityLabel, "Sent")
    }

    // MARK: - Retry tap

    func test_failed_tapInvokesRetryClosure() {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        var retryCount = 0
        cell.configure(
            message: makeMessage(direction: .outgoing, status: .failed),
            onRetry: { retryCount += 1 }
        )
        cell.simulateBubbleTapForTest()
        XCTAssertEqual(retryCount, 1)
    }

    func test_nonFailed_tapIsNoOp() {
        // Sent / pending / received bubbles must not fire the
        // retry closure. `configure(message:onRetry:)` only stores
        // the closure when status == .failed && direction ==
        // .outgoing, so a tap on a non-failed bubble reads `nil`
        // and does nothing.
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        var retryCount = 0
        cell.configure(
            message: makeMessage(direction: .outgoing, status: .sent),
            onRetry: { retryCount += 1 }
        )
        cell.simulateBubbleTapForTest()
        XCTAssertEqual(retryCount, 0,
                       "non-failed bubbles must not fire the retry closure")
    }

    func test_reconfigureFromFailedToSent_dropsRetry() {
        // Cell reuse: a failed bubble that flips to sent must
        // forget its retry closure, so a stray tap on the
        // now-sent bubble doesn't re-fire it.
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuseID)
        var retryCount = 0
        let id = UUID()
        cell.configure(
            message: makeMessage(id: id, direction: .outgoing, status: .failed),
            onRetry: { retryCount += 1 }
        )
        cell.configure(
            message: makeMessage(id: id, direction: .outgoing, status: .sent),
            onRetry: { retryCount += 1 }
        )
        cell.simulateBubbleTapForTest()
        XCTAssertEqual(retryCount, 0,
                       "reconfigured-to-sent bubble must drop its retry closure")
    }

    // MARK: - Helpers

    private func statusIcon(in cell: ChatBubbleCell) -> UIImageView {
        guard let icon = find(in: cell.contentView, identifier: "chat.bubble.status")
                as? UIImageView else {
            fatalError("status icon not found")
        }
        return icon
    }

    private func find(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for sub in view.subviews {
            if let found = find(in: sub, identifier: identifier) { return found }
        }
        return nil
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
        id: UUID = UUID(),
        direction: MessageDirection,
        body: String = "hi",
        status: MessageStatus? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            groupID: "aa".repeated(32),
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: "11".repeated(48),
            body: body,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: direction,
            status: status ?? (direction == .incoming ? .received : .sent),
            replyToMessageID: nil,
            groupType: .tyranny
        )
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
