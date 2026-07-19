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

// MARK: - Join

struct JoinScreen {
    let app: XCUIApplication

    var labelField: XCUIElement { app.textFields["join.display_label_field"] }
    var sendButton: XCUIElement { app.buttons["join.send_button"] }
    var cancelButton: XCUIElement { app.buttons["join.cancel_button"] }

    @discardableResult
    func waitReady(timeout: TimeInterval = 20) -> Bool {
        sendButton.waitForExistence(timeout: timeout)
    }

    func typeLabel(_ label: String) {
        if labelField.waitForExistence(timeout: 5) {
            labelField.tap()
            labelField.typeText(label)
        }
    }

    func send() {
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Join Send button missing")
        sendButton.tap()
    }

    /// The request ships the moment Send is tapped; the flow then shows
    /// an "awaiting approval" state. We don't need to keep it open —
    /// the sealed invitation lands via the inbox pump regardless — so
    /// cancel to free the modal and switch identities.
    func dismissAfterSend() {
        // Give the send task a beat to actually ship before we tear the
        // modal down.
        _ = app.otherElements["join.awaiting_approval"].waitForExistence(timeout: 8)
        if cancelButton.exists { cancelButton.tap() }
    }
}

// MARK: - Approve Requests

struct ApproveRequestsScreen {
    let app: XCUIApplication

    var toolbarButton: XCUIElement { app.buttons["approve_requests.toolbar_button"] }
    var successBanner: XCUIElement { app.staticTexts["approve_requests.success_banner"] }
    var closeButton: XCUIElement { app.buttons["approve_requests.close_button"] }

    /// The badge only appears once the (buffered) join request has been
    /// pumped in under the now-active admin identity.
    @discardableResult
    func waitForBadge(timeout: TimeInterval = 40) -> Bool {
        toolbarButton.waitForExistence(timeout: timeout)
    }

    func open() {
        XCTAssertTrue(waitForBadge(), "approve-requests toolbar button never appeared")
        toolbarButton.tap()
    }

    /// The request only lands in the admin's list once their intro
    /// pump has re-subscribed under the now-active identity and the
    /// (buffered) request is decoded — a few seconds after the identity
    /// switch. The sheet updates reactively, so wait generously.
    func approveFirst() {
        // The request card's `.accessibilityIdentifier` propagates to
        // its child buttons, overriding their own ids — so the Approve
        // control surfaces as `approve_requests.row.<id>` with label
        // "Approve". Match on that pair.
        let approve = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'approve_requests.row.' AND label == 'Approve'")
        ).firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 45),
                      "no approve button in the requests list")
        approve.tap()
    }

    /// The approve does a real Poseidon `update_commitment` proof, so
    /// the success banner can take a few seconds.
    @discardableResult
    func waitForSuccess(timeout: TimeInterval = 60) -> Bool {
        successBanner.waitForExistence(timeout: timeout)
    }

    func close() {
        if closeButton.waitForExistence(timeout: 3) { closeButton.tap() }
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
        app.staticTexts[text].waitForExistence(timeout: timeout)
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
