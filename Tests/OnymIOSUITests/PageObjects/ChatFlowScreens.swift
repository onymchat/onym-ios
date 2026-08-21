import XCTest

/// Page objects for the create-group → share-invite → join → approve →
/// chat pipeline exercised by `MultiIdentityChatUITests`. Kept together
/// because they're only used by that one end-to-end flow.

// MARK: - Create Group

struct CreateGroupScreen {
    let app: XCUIApplication

    /// Enter the flow from the Chats tab — empty state (first group) or
    /// the toolbar "+" (subsequent).
    func open() {
        let emptyCTA = app.buttons["chats.create_group_empty_cta"]
        let toolbar = app.buttons["chats.create_group_toolbar"]
        if emptyCTA.waitForExistence(timeout: 4) {
            emptyCTA.tap()
        } else if toolbar.exists {
            toolbar.tap()
        } else {
            XCTFail("no create-group entry point on the Chats tab")
        }
    }

    var nameField: XCUIElement { app.textFields["create_group.step1.name_field"] }

    func typeName(_ name: String) {
        XCTAssertTrue(nameField.waitForExistence(timeout: 5),
                      "create-group name field never appeared")
        nameField.tap()
        nameField.typeText(name)
    }

    /// Type into the multi-line invitation-message field on step 1. The
    /// SwiftUI vertical TextField can surface as either a text view or a
    /// text field, so accept whichever the runtime exposes.
    func typeInvitation(_ text: String) {
        let id = "create_group.step1.invitation_field"
        let tv = app.textViews[id]
        let field = tv.waitForExistence(timeout: 3) ? tv : app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "create-group invitation field never appeared")
        field.tap()
        field.typeText(text)
    }

    func tapNext() {
        let next = app.buttons["create_group.step1.next_button"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "step-1 Next button missing")
        next.tap()
    }

    func tapCreate() {
        let create = app.buttons["create_group.step2.create_button"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "step-2 Create button missing")
        create.tap()
    }

    /// Success lands after the (~3-4s) real Poseidon proof + the faked
    /// anchor, so allow a generous window.
    @discardableResult
    func waitForSuccess(timeout: TimeInterval = 90) -> Bool {
        app.buttons["create_group.share_invite_button"].waitForExistence(timeout: timeout)
    }

    func tapShareInvite() {
        app.buttons["create_group.share_invite_button"].tap()
    }

    /// Dismiss the success screen (no invite share) back to the Chats
    /// list. Used by flows that just need the group to exist.
    func tapDone() {
        let done = app.buttons["create_group.done_button"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "create-group Done button missing")
        done.tap()
    }
}

// MARK: - Share Invite

struct ShareInviteScreen {
    let app: XCUIApplication

    var copyButton: XCUIElement { app.buttons["share_invite.copy_button"] }
    var doneButton: XCUIElement { app.buttons["share_invite.done_button"] }

    @discardableResult
    func waitReady(timeout: TimeInterval = 30) -> Bool {
        copyButton.waitForExistence(timeout: timeout)
    }

    /// Read the minted invite link straight off the Copy button's
    /// accessibility value (exposed under DEBUG) — avoids the system
    /// "paste from …" prompt a real `UIPasteboard` read would trigger.
    /// Also taps Copy for realism (writing the pasteboard never prompts).
    func readInviteLink() -> String? {
        XCTAssertTrue(copyButton.waitForExistence(timeout: 15),
                      "share-invite Copy button never appeared")
        let link = copyButton.value as? String
        copyButton.tap()
        return link
    }

    func done() {
        if doneButton.waitForExistence(timeout: 3) { doneButton.tap() }
    }
}

// MARK: - Join (pending chat)

/// A tapped invite link no longer opens a screen of its own: the request
/// goes out on the tap and the app pushes the chat it created, pending
/// until the founder lets the joiner in. So this page object waits on
/// that thread rather than driving a form.
struct PendingChatScreen {
    let app: XCUIApplication

    var waiting: XCUIElement { app.staticTexts["pending_chat.waiting"] }
    var stuck: XCUIElement { app.staticTexts["pending_chat.stuck"] }

    /// The request ships without a tap, so "ready" is the waiting state
    /// itself — reaching it is proof the join left the device.
    @discardableResult
    func waitReady(timeout: TimeInterval = 20) -> Bool {
        waiting.waitForExistence(timeout: timeout)
    }

    /// Nothing has to stay open — the sealed invitation lands via the
    /// inbox pump regardless, and the row survives a relaunch.
    func back() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists { backButton.tap() }
    }
}

// MARK: - Join requests (in-thread)

/// Join requests are no longer a separate screen. The founder accepts or
/// declines from a row inside the group's own chat thread, so this page
/// object drives the thread rather than a modal.
struct JoinRequestRow {
    let app: XCUIApplication

    /// Accept buttons carry `chat.join_request.accept.<requestID>`.
    private var acceptButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'chat.join_request.accept.'")
        ).firstMatch
    }

    private var declineButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'chat.join_request.decline.'")
        ).firstMatch
    }

    /// The row only appears once the admin's intro pump has
    /// re-subscribed under the now-active identity and decoded the
    /// buffered request — a few seconds after an identity switch. The
    /// thread updates reactively, so wait generously.
    @discardableResult
    func waitForRequest(timeout: TimeInterval = 45) -> Bool {
        acceptButton.waitForExistence(timeout: timeout)
    }

    func acceptFirst() {
        XCTAssertTrue(waitForRequest(), "no join-request row appeared in the thread")
        acceptButton.tap()
    }

    func declineFirst() {
        XCTAssertTrue(waitForRequest(), "no join-request row appeared in the thread")
        declineButton.tap()
    }

    /// Accept runs a real Poseidon `update_commitment` proof plus a
    /// relayer round-trip, so the "joined" notice replacing the row can
    /// take a while.
    @discardableResult
    /// Matches the notice by its accessibility identifier and then by
    /// the alias appearing inside it, rather than by the whole English
    /// sentence.
    ///
    /// The sentence now comes from the string catalog, so asserting on
    /// `"\(alias) joined"` made the flow pass only in English. The alias
    /// is user data and appears in every translation; the identifier is
    /// stable by construction.
    func waitForJoinedNotice(alias: String, timeout: TimeInterval = 60) -> Bool {
        // One predicate over the element itself, not `.containing(...)`:
        // that filters by *descendants*, and a static text backed by a
        // `UILabel` has none — so the chained form matched nothing and
        // this always timed out. Matches the shape used everywhere else
        // in this suite.
        let notice = app.staticTexts
            .matching(
                NSPredicate(
                    format: "identifier == %@ AND label CONTAINS[c] %@",
                    "chat.system_notice",
                    alias
                )
            )
            .firstMatch
        return notice.waitForExistence(timeout: timeout)
    }
}

// MARK: - Chat Thread

struct ChatThreadScreen {
    let app: XCUIApplication

    var input: XCUIElement { app.textViews["chat.input.textview"] }
    var sendButton: XCUIElement { app.buttons["chat.input.send"] }
    /// The chat now uses the standard SwiftUI navigation bar, so "back"
    /// is the system nav-bar back button (leading item).
    var backButton: XCUIElement { app.navigationBars.buttons.element(boundBy: 0) }

    @discardableResult
    func waitReady(timeout: TimeInterval = 20) -> Bool {
        input.waitForExistence(timeout: timeout)
    }

    func send(_ text: String) {
        XCTAssertTrue(input.waitForExistence(timeout: 10), "chat input never appeared")
        input.tap()
        input.typeText(text)
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "chat send button missing")
        sendButton.tap()
    }

    @discardableResult
    func waitForMessage(_ text: String, timeout: TimeInterval = 25) -> Bool {
        // Bubble bodies render in a link-aware UITextView, which
        // XCUITest exposes as a text view whose `value` is the text —
        // not as a static text. Other message renderings (system
        // notices, quotes) remain labels, so accept either.
        let bubble = app.textViews.matching(
            NSPredicate(format: "value == %@", text)
        ).firstMatch
        let label = app.staticTexts[text]
        let either = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in bubble.exists || label.exists },
            object: nil
        )
        return XCTWaiter().wait(for: [either], timeout: timeout) == .completed
    }

    /// The delivery-status glyph exposes its state via accessibilityLabel
    /// ("Sending" / "Sent" / "Delivered" / "Read"). Matches when *any*
    /// outgoing bubble reports `label`.
    @discardableResult
    func waitForStatus(_ label: String, timeout: TimeInterval = 40) -> Bool {
        let predicate = NSPredicate(
            format: "identifier == %@ AND label == %@", "chat.bubble.status", label
        )
        return app.images.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    func back() {
        if backButton.waitForExistence(timeout: 3) { backButton.tap() }
    }
}
