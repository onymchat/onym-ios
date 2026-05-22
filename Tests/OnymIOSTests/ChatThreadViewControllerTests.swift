import XCTest
@testable import OnymIOS

/// Smoke tests for `ChatThreadViewController`. PR 5 ships an empty
/// shell — these tests pin the wiring contract the SwiftUI bridge
/// depends on:
///
///   - `viewDidLoad` doesn't crash.
///   - `update(groupName:)` writes through to a label the bridge
///     calls every render.
///   - The back / info buttons invoke their closures when tapped.
///
/// Message rendering, input, keyboard behavior arrive in later PRs;
/// the assertions here are intentionally narrow so they don't
/// constrain the layout work yet to come.
@MainActor
final class ChatThreadViewControllerTests: XCTestCase {

    func test_loadView_doesNotCrash() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func test_updateGroupName_writesThroughToTitleLabel() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(groupName: "Family")
        XCTAssertEqual(titleLabel(in: vc)?.text, "Family")
    }

    func test_updateGroupName_emptyFallsBackToChat() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(groupName: "")
        XCTAssertEqual(titleLabel(in: vc)?.text, "Chat",
                       "empty group names fall back to the generic title so the bar isn't blank")
    }

    func test_backButtonTap_invokesOnBackClosure() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        var backCount = 0
        vc.onBack = { backCount += 1 }
        backButton(in: vc)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(backCount, 1)
    }

    func test_infoButtonTap_invokesOnShowMembersClosure() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        var showCount = 0
        vc.onShowMembers = { showCount += 1 }
        infoButton(in: vc)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(showCount, 1)
    }

    // MARK: - Message list rendering (PR 6)

    func test_updateMessages_empty_rendersZeroRows() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(messages: [])
        XCTAssertEqual(tableView(in: vc)?.numberOfRows(inSection: 0), 0)
    }

    func test_updateMessages_appendsRowsForEach() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        let msgs = [
            makeMessage(body: "one", direction: .incoming),
            makeMessage(body: "two", direction: .outgoing),
            makeMessage(body: "three", direction: .incoming),
        ]
        vc.update(messages: msgs)
        XCTAssertEqual(tableView(in: vc)?.numberOfRows(inSection: 0), 3)
    }

    func test_updateMessages_subsequentAdd_reflectsDiff() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        let m1 = makeMessage(body: "first", direction: .incoming)
        vc.update(messages: [m1])
        XCTAssertEqual(tableView(in: vc)?.numberOfRows(inSection: 0), 1)

        let m2 = makeMessage(body: "second", direction: .outgoing)
        vc.update(messages: [m1, m2])
        XCTAssertEqual(tableView(in: vc)?.numberOfRows(inSection: 0), 2)
    }

    func test_updateMessages_unsortedInput_isSortedAscending() {
        // Defensive: the repository's contract is to emit ascending
        // snapshots, but a future caller / test stub might violate
        // it. The controller sorts before applying so row order is
        // always chronological.
        //
        // The assertion reads cell content via `cellForRow(at:)`,
        // which only returns currently-visible rows. Place the
        // controller in a real window so Auto Layout (including
        // the input panel's `keyboardLayoutGuide` constraint)
        // resolves and the table view ends up tall enough to host
        // all three rows.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        let vc = ChatThreadViewController()
        window.rootViewController = vc
        window.isHidden = false

        let oldest = makeMessage(body: "1", direction: .incoming,
                                 sentAt: Date(timeIntervalSince1970: 1_700_000_000))
        let middle = makeMessage(body: "2", direction: .outgoing,
                                 sentAt: Date(timeIntervalSince1970: 1_700_000_100))
        let newest = makeMessage(body: "3", direction: .incoming,
                                 sentAt: Date(timeIntervalSince1970: 1_700_000_200))
        // Out-of-order input.
        vc.update(messages: [newest, oldest, middle])
        vc.view.layoutIfNeeded()
        let table = tableView(in: vc)!
        table.layoutIfNeeded()

        // Row 0 = oldest (top), row 2 = newest (bottom).
        XCTAssertEqual(table.numberOfRows(inSection: 0), 3)
        XCTAssertEqual(cellBodyText(in: table, row: 0), "1")
        XCTAssertEqual(cellBodyText(in: table, row: 1), "2")
        XCTAssertEqual(cellBodyText(in: table, row: 2), "3")
    }

    func test_updateMessages_removeOne_shrinksTable() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        let m1 = makeMessage(body: "stays", direction: .incoming)
        let m2 = makeMessage(body: "drops", direction: .outgoing)
        vc.update(messages: [m1, m2])
        XCTAssertEqual(tableView(in: vc)?.numberOfRows(inSection: 0), 2)

        vc.update(messages: [m1])
        XCTAssertEqual(tableView(in: vc)?.numberOfRows(inSection: 0), 1)
    }

    // MARK: - Input panel wiring (PR 7 / PR 8)

    func test_inputPanel_isHosted_andClearsTextOnSendTap() {
        // Tapping send clears the field — PR 7 contract.
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        guard let panel = inputPanel(in: vc) else {
            return XCTFail("input panel not found in controller hierarchy")
        }
        panel.text = "hello"
        XCTAssertTrue(sendButton(in: panel).isEnabled)

        sendButton(in: panel).sendActions(for: .touchUpInside)
        XCTAssertEqual(panel.text, "",
                       "tapping send must clear the field")
        XCTAssertFalse(sendButton(in: panel).isEnabled,
                       "after clearing, the send button must disable again")
    }

    func test_inputPanel_send_invokesOnSendTapped_withTrimmedBody() {
        // PR 8 contract: the controller forwards the panel's
        // trimmed body to `onSendTapped` (the SwiftUI bridge
        // points this at `SendMessageInteractor.send`).
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        guard let panel = inputPanel(in: vc) else {
            return XCTFail("input panel not found in controller hierarchy")
        }
        var receivedBodies: [String] = []
        vc.onSendTapped = { receivedBodies.append($0) }

        panel.text = "   hello   "
        sendButton(in: panel).sendActions(for: .touchUpInside)
        XCTAssertEqual(receivedBodies, ["hello"],
                       "the controller must forward the trimmed body to the host's send dispatcher")
    }

    func test_inputPanel_send_doesNotFire_forWhitespaceOnlyBody() {
        // Belt + braces. The input panel already gates the button
        // disabled for whitespace-only input, but if anything ever
        // bypasses that (programmatic tap, accessibility action),
        // the controller's forwarder must not invoke the
        // dispatcher with an empty body.
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        guard let panel = inputPanel(in: vc) else {
            return XCTFail("input panel not found")
        }
        var fired = false
        vc.onSendTapped = { _ in fired = true }

        panel.text = "   "
        sendButton(in: panel).sendActions(for: .touchUpInside)
        XCTAssertFalse(fired,
                       "whitespace-only body must not reach the send dispatcher")
    }

    private func inputPanel(in vc: UIViewController) -> ChatInputPanelView? {
        find(in: vc.view) { $0 is ChatInputPanelView } as? ChatInputPanelView
    }

    private func sendButton(in panel: ChatInputPanelView) -> UIButton {
        guard let b = find(in: panel, where: {
            $0.accessibilityIdentifier == "chat.input.send"
        }) as? UIButton else {
            fatalError("send button not found")
        }
        return b
    }

    // MARK: - Auto-scroll heuristic

    func test_isNearBottom_emptyContent_isTrue() {
        // No messages → content shorter than viewport → trivially
        // "at the bottom"; auto-scroll has nothing to do.
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.isNearBottom)
    }

    func test_isNearBottom_atContentEnd_isTrue() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        let table = tableView(in: vc)!
        table.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        // Simulate scrolled-to-end content. The threshold is 100pt;
        // setting offsetY to exactly maxOffset means we're 0pt from
        // the bottom, well within range.
        table.contentSize = CGSize(width: 320, height: 2000)
        table.contentOffset = CGPoint(x: 0, y: 1520)  // 2000 - 480 = 1520
        XCTAssertTrue(vc.isNearBottom)
    }

    func test_isNearBottom_scrolledUp_isFalse() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        let table = tableView(in: vc)!
        table.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        table.contentSize = CGSize(width: 320, height: 2000)
        // 500pt away from the bottom — way past the 100pt threshold.
        table.contentOffset = CGPoint(x: 0, y: 1020)
        XCTAssertFalse(vc.isNearBottom)
    }

    // MARK: - Helpers

    private func tableView(in vc: UIViewController) -> UITableView? {
        find(in: vc.view) { $0 is UITableView } as? UITableView
    }

    private func find(in view: UIView, where predicate: (UIView) -> Bool) -> UIView? {
        if predicate(view) { return view }
        for sub in view.subviews {
            if let found = find(in: sub, where: predicate) { return found }
        }
        return nil
    }

    private func makeMessage(
        body: String,
        direction: MessageDirection,
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            groupID: "aa".repeated(32),
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: "11".repeated(48),
            body: body,
            sentAt: sentAt,
            direction: direction,
            status: direction == .incoming ? .received : .sent,
            groupType: .tyranny
        )
    }

    private func cellBodyText(in table: UITableView, row: Int) -> String? {
        let cell = table.cellForRow(at: IndexPath(row: row, section: 0))
        guard let cv = cell?.contentView else { return nil }
        return findLabelText(in: cv)
    }

    private func findLabelText(in view: UIView) -> String? {
        if let label = view as? UILabel { return label.text }
        for sub in view.subviews {
            if let text = findLabelText(in: sub) { return text }
        }
        return nil
    }

    // MARK: - Subview lookup
    //
    // The controller's subviews are private; tests reach them via
    // accessibility identifiers — same approach the create-group
    // UI tests use. Keeps the production code free of test seams.

    private func titleLabel(in vc: UIViewController) -> UILabel? {
        find(in: vc.view, identifier: "chat.title") as? UILabel
    }

    private func backButton(in vc: UIViewController) -> UIButton? {
        find(in: vc.view, identifier: "chat.back") as? UIButton
    }

    private func infoButton(in vc: UIViewController) -> UIButton? {
        find(in: vc.view, identifier: "chat.info") as? UIButton
    }

    private func find(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for sub in view.subviews {
            if let found = find(in: sub, identifier: identifier) { return found }
        }
        return nil
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
