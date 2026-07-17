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
        vc.update(groupName: "Family", memberCount: 0)
        XCTAssertEqual(titleLabel(in: vc)?.text, "Family")
    }

    func test_updateGroupName_emptyFallsBackToChat() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(groupName: "", memberCount: 0)
        XCTAssertEqual(titleLabel(in: vc)?.text, "Chat",
                       "empty group names fall back to the generic title so the bar isn't blank")
    }

    func test_memberCount_zeroOrOne_hidesSubtitle() {
        // Singleton groups (just the user) don't need a member
        // count; nothing-known groups would show "0 members"
        // awkwardly. Both hide the subtitle.
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()

        vc.update(groupName: "Group", memberCount: 0)
        XCTAssertTrue(memberCountLabel(in: vc)?.isHidden ?? false)

        vc.update(groupName: "Group", memberCount: 1)
        XCTAssertTrue(memberCountLabel(in: vc)?.isHidden ?? false)
    }

    func test_memberCount_twoOrMore_showsSubtitleWithPluralization() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()

        vc.update(groupName: "Group", memberCount: 2)
        XCTAssertFalse(memberCountLabel(in: vc)?.isHidden ?? true)
        XCTAssertEqual(memberCountLabel(in: vc)?.text, "2 members")

        vc.update(groupName: "Group", memberCount: 5)
        XCTAssertEqual(memberCountLabel(in: vc)?.text, "5 members")
    }

    // MARK: - Empty state (PR 10)

    func test_emptyMessageList_showsEmptyStateLabel() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(messages: [])
        XCTAssertFalse(emptyStateLabel(in: vc)?.isHidden ?? true,
                       "empty state must be visible when there are no messages")
    }

    func test_nonEmptyMessageList_hidesEmptyState() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(messages: [makeMessage(body: "hi", direction: .incoming)])
        XCTAssertTrue(emptyStateLabel(in: vc)?.isHidden ?? false,
                      "empty state must disappear once a message lands")
    }

    func test_messagesClearedAgain_showsEmptyState() {
        // PR 10 contract: empty state toggle is symmetric — if all
        // messages get deleted (rare today, possible later), the
        // empty state should come back without the controller
        // needing a reset.
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(messages: [makeMessage(body: "hi", direction: .incoming)])
        vc.update(messages: [])
        XCTAssertFalse(emptyStateLabel(in: vc)?.isHidden ?? true)
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

    // MARK: - Retry wiring (PR 9)

    func test_failedBubble_tap_invokesOnRetryRequested() {
        // Window-hosted to give the table real frames so the
        // failed cell actually mounts.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        let vc = ChatThreadViewController()
        window.rootViewController = vc
        window.isHidden = false

        let failed = makeMessage(body: "uh oh", direction: .outgoing)
        let failedRow = ChatMessage(
            id: failed.id,
            groupID: failed.groupID,
            ownerIdentityID: failed.ownerIdentityID,
            senderBlsPubkeyHex: failed.senderBlsPubkeyHex,
            body: failed.body,
            sentAt: failed.sentAt,
            direction: failed.direction,
            status: .failed,
            replyToMessageID: nil,
            groupType: failed.groupType
        )

        var retriedIDs: [UUID] = []
        vc.onRetryRequested = { retriedIDs.append($0) }
        vc.update(messages: [failedRow])
        vc.view.layoutIfNeeded()
        let table = tableView(in: vc)!
        table.layoutIfNeeded()

        guard let cell = table.cellForRow(at: IndexPath(row: 0, section: 0))
                as? ChatBubbleCell else {
            return XCTFail("failed bubble cell not mounted")
        }
        cell.simulateBubbleTapForTest()
        XCTAssertEqual(retriedIDs, [failedRow.id],
                       "tapping a failed bubble must fire onRetryRequested with the message id")
    }

    // MARK: - Diffable reconfigure (PR 9)

    func test_statusFlip_reconfiguresVisibleCell() {
        // The diffable identity is just `UUID`, so a status flip
        // (same id, different content) must use `reconfigureItems`
        // to re-run the cell provider. Without that, the bubble's
        // status glyph would stay stale until cell reuse.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        let vc = ChatThreadViewController()
        window.rootViewController = vc
        window.isHidden = false

        let id = UUID()
        let pending = ChatMessage(
            id: id,
            groupID: "aa".repeated(32),
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: "11".repeated(48),
            body: "hi",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .outgoing,
            status: .pending,
            replyToMessageID: nil,
            groupType: .tyranny
        )
        vc.update(messages: [pending])
        vc.view.layoutIfNeeded()
        let table = tableView(in: vc)!
        table.layoutIfNeeded()

        guard let cell = table.cellForRow(at: IndexPath(row: 0, section: 0))
                as? ChatBubbleCell else {
            return XCTFail("pending bubble cell not mounted")
        }
        let pendingIcon = find(in: cell.contentView) {
            $0.accessibilityIdentifier == "chat.bubble.status"
        } as? UIImageView
        XCTAssertEqual(pendingIcon?.accessibilityLabel, "Sending")

        // Flip to .sent — same id, different status.
        let sentRow = ChatMessage(
            id: id,
            groupID: pending.groupID,
            ownerIdentityID: pending.ownerIdentityID,
            senderBlsPubkeyHex: pending.senderBlsPubkeyHex,
            body: pending.body,
            sentAt: pending.sentAt,
            direction: .outgoing,
            status: .sent,
            replyToMessageID: nil,
            groupType: .tyranny
        )
        vc.update(messages: [sentRow])
        table.layoutIfNeeded()

        // Same cell instance (reconfigured, not reloaded). The
        // status glyph swapped.
        let sentIcon = find(in: cell.contentView) {
            $0.accessibilityIdentifier == "chat.bubble.status"
        } as? UIImageView
        XCTAssertEqual(sentIcon?.accessibilityLabel, "Sent",
                       "reconfigureItems must re-run the cell provider so the glyph updates")
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

    // MARK: - Sender differentiation (run grouping + name headers)

    func test_runGrouping_headerOnlyAtStartOfSameSenderRun() {
        let vc = mountedController()
        let alice = "aa".repeated(48)
        let bob = "bb".repeated(48)
        // Alice, Alice, Bob — header on row 0 (run start) and row 2
        // (sender change), suppressed on row 1 (mid-run).
        let msgs = [
            incoming(sender: alice, body: "hi", at: 1),
            incoming(sender: alice, body: "again", at: 2),
            incoming(sender: bob, body: "yo", at: 3),
        ]
        vc.update(messages: msgs)
        let table = layoutTable(in: vc)

        XCTAssertFalse(senderHeaderHidden(in: table, row: 0), "run start shows header")
        XCTAssertTrue(senderHeaderHidden(in: table, row: 1), "mid-run hides header")
        XCTAssertFalse(senderHeaderHidden(in: table, row: 2), "sender change shows header")
    }

    func test_outgoingMessages_neverShowHeader() {
        let vc = mountedController()
        vc.update(messages: [outgoing(sender: "cc".repeated(48), body: "mine", at: 1)])
        let table = layoutTable(in: vc)
        XCTAssertTrue(senderHeaderHidden(in: table, row: 0),
                      "own messages are obvious from alignment + color — no header")
    }

    func test_oneOnOneGroup_suppressesHeader() {
        let vc = mountedController()
        let peer = "dd".repeated(48)
        vc.update(messages: [
            incoming(sender: peer, body: "hey", at: 1, groupType: .oneOnOne),
        ])
        let table = layoutTable(in: vc)
        XCTAssertTrue(senderHeaderHidden(in: table, row: 0),
                      "1-on-1 chats name no one — there's only one other person")
    }

    func test_header_usesAliasFromMemberProfiles() {
        let vc = mountedController()
        let alice = "aa".repeated(48)
        vc.update(memberProfiles: [alice: profile(alias: "Alice")])
        vc.update(messages: [incoming(sender: alice, body: "hi", at: 1)])
        let table = layoutTable(in: vc)
        XCTAssertEqual(senderHeaderText(in: table, row: 0), "Alice")
    }

    func test_header_fallsBackToFingerprint_whenAliasMissing() {
        let vc = mountedController()
        let alice = "aa".repeated(48)
        // No alias for this sender → short BLS fingerprint fallback.
        vc.update(messages: [incoming(sender: alice, body: "hi", at: 1)])
        let table = layoutTable(in: vc)
        XCTAssertEqual(senderHeaderText(in: table, row: 0),
                       "BLS " + String(alice.prefix(8)))
    }

    func test_profileUpdate_refreshesRenderedHeaderName() {
        // A joiner's alias arriving after their message is on screen
        // must repaint the header (the bridge calls update(memberProfiles:)
        // every render).
        let vc = mountedController()
        let alice = "aa".repeated(48)
        vc.update(messages: [incoming(sender: alice, body: "hi", at: 1)])
        var table = layoutTable(in: vc)
        XCTAssertEqual(senderHeaderText(in: table, row: 0), "BLS " + String(alice.prefix(8)))

        vc.update(memberProfiles: [alice: profile(alias: "Alice")])
        table = layoutTable(in: vc)
        XCTAssertEqual(senderHeaderText(in: table, row: 0), "Alice",
                       "a later profile update must refresh the on-screen header")
    }

    // MARK: - Reply quote (PR 2)

    func test_reply_rendersQuoteResolvedFromTargetSender() {
        let vc = mountedController()
        let alice = "aa".repeated(48)
        vc.update(memberProfiles: [alice: profile(alias: "Alice")])
        let original = incoming(sender: alice, body: "the original", at: 1)
        let reply = replyMessage(
            sender: "cc".repeated(48), body: "agreed", to: original.id, at: 2
        )
        vc.update(messages: [original, reply])
        let table = layoutTable(in: vc)

        // Row 1 is the reply; its quote must name the target's sender
        // and preview the target's body.
        XCTAssertEqual(quoteName(in: table, row: 1), "Alice")
        XCTAssertEqual(quoteSnippet(in: table, row: 1), "the original")
        // Row 0 (the original, a non-reply) shows no quote.
        XCTAssertTrue(quoteHidden(in: table, row: 0))
    }

    func test_reply_unknownTarget_showsUnavailablePlaceholder() {
        let vc = mountedController()
        let reply = replyMessage(
            sender: "cc".repeated(48), body: "agreed", to: UUID(), at: 1
        )
        vc.update(messages: [reply])
        let table = layoutTable(in: vc)
        XCTAssertEqual(quoteSnippet(in: table, row: 0), "Message unavailable",
                       "a reply to a message we don't have renders the placeholder")
    }

    func test_scrollAndHighlight_unknownID_isNoOp() {
        let vc = mountedController()
        vc.update(messages: [incoming(sender: "aa".repeated(48), body: "hi", at: 1)])
        _ = layoutTable(in: vc)
        // Must not crash / trap when the target isn't in the snapshot.
        vc.scrollAndHighlight(messageID: UUID())
    }

    // MARK: - Sender-test helpers

    private func replyMessage(
        sender: String, body: String, to target: UUID, at seconds: TimeInterval
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(), groupID: "aa".repeated(32), ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: sender, body: body,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            direction: .outgoing, status: .sent,
            replyToMessageID: target, groupType: .tyranny
        )
    }

    private func quoteLabel(
        in table: UITableView, row: Int, identifier: String
    ) -> UILabel? {
        let cell = table.cellForRow(at: IndexPath(row: row, section: 0))
        guard let cv = cell?.contentView else { return nil }
        return find(in: cv) { $0.accessibilityIdentifier == identifier } as? UILabel
    }

    private func quoteName(in table: UITableView, row: Int) -> String? {
        quoteLabel(in: table, row: row, identifier: "chat.bubble.quote.name")?.text
    }

    private func quoteSnippet(in table: UITableView, row: Int) -> String? {
        quoteLabel(in: table, row: row, identifier: "chat.bubble.quote.snippet")?.text
    }

    private func quoteHidden(in table: UITableView, row: Int) -> Bool {
        let cell = table.cellForRow(at: IndexPath(row: row, section: 0))
        guard let cv = cell?.contentView,
              let container = find(in: cv, where: { $0.accessibilityIdentifier == "chat.bubble.quote" })
        else { return true }
        return container.isHidden
    }

    private func mountedController() -> ChatThreadViewController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        let vc = ChatThreadViewController()
        window.rootViewController = vc
        window.isHidden = false
        return vc
    }

    private func layoutTable(in vc: ChatThreadViewController) -> UITableView {
        vc.view.layoutIfNeeded()
        let table = tableView(in: vc)!
        table.layoutIfNeeded()
        return table
    }

    private func senderHeader(in table: UITableView, row: Int) -> UILabel? {
        let cell = table.cellForRow(at: IndexPath(row: row, section: 0))
        guard let cv = cell?.contentView else { return nil }
        return find(in: cv) { $0.accessibilityIdentifier == "chat.bubble.sender" } as? UILabel
    }

    private func senderHeaderHidden(in table: UITableView, row: Int) -> Bool {
        senderHeader(in: table, row: row)?.isHidden ?? true
    }

    private func senderHeaderText(in table: UITableView, row: Int) -> String? {
        senderHeader(in: table, row: row)?.text
    }

    private func profile(alias: String) -> MemberProfile {
        MemberProfile(alias: alias, inboxPublicKey: Data(repeating: 1, count: 32),
                      sendingPubkey: Data(repeating: 2, count: 32))
    }

    private func incoming(
        sender: String, body: String, at seconds: TimeInterval,
        groupType: SEPGroupType = .tyranny
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(), groupID: "aa".repeated(32), ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: sender, body: body,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            direction: .incoming, status: .received, replyToMessageID: nil, groupType: groupType
        )
    }

    private func outgoing(
        sender: String, body: String, at seconds: TimeInterval
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(), groupID: "aa".repeated(32), ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: sender, body: body,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            direction: .outgoing, status: .sent, replyToMessageID: nil, groupType: .tyranny
        )
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
            replyToMessageID: nil,
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

    private func memberCountLabel(in vc: UIViewController) -> UILabel? {
        find(in: vc.view, identifier: "chat.title.member_count") as? UILabel
    }

    private func emptyStateLabel(in vc: UIViewController) -> UILabel? {
        find(in: vc.view, identifier: "chat.empty_state") as? UILabel
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
