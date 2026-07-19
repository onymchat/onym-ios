import XCTest

/// Covers Chats list → swipe-to-delete a chat, gated by a confirmation
/// dialog. Deletion wipes the chat + its messages from this device
/// (`ChatsFlow.deleteChat` → `MessageRepository.removeForGroup` +
/// `GroupRepository.delete`, both unit-tested); this asserts the swipe
/// affordance, the confirm gate, and that the row disappears.
///
/// Uses the `--ui-loopback` harness so the Founder group can be created
/// offline (no relays / relayer), same as `MultiIdentityChatUITests`.
final class DeleteChatUITests: XCTestCase {
    private let baseArgs = [
        "--ui-testing", "--mock-biometric", "--ui-loopback",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_swipeToDelete_requiresConfirmation_thenRemovesRow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-keychain"] + baseArgs
        app.launch()
        defer { app.terminate() }

        // Create a Founder group so the Chats list has a row to delete.
        let create = CreateGroupScreen(app: app)
        create.open()
        create.typeName("DeleteMe")
        create.tapNext()
        create.tapCreate()
        XCTAssertTrue(create.waitForSuccess(),
                      "Founder group creation never reached the success screen")
        create.tapDone()

        // The new chat appears on the list.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'DeleteMe'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "'DeleteMe' chat never appeared on the Chats list")

        // Swipe to reveal the destructive Delete action.
        row.swipeLeft()
        let deleteAction = app.buttons["Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5),
                      "swipe Delete action never appeared")

        // The swipe alone must NOT delete — the confirmation gates it.
        deleteAction.tap()
        // The confirm button surfaces twice in the a11y tree — take the
        // first match by identifier.
        let confirm = app.buttons["chats.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "delete confirmation dialog never appeared")
        // Still present until the user confirms.
        XCTAssertTrue(app.staticTexts["DeleteMe"].exists,
                      "chat must survive until the confirmation is accepted")
        confirm.tap()

        // Confirmed → the row (and its messages) are gone.
        XCTAssertTrue(app.staticTexts["DeleteMe"].waitForNonExistence(timeout: 5),
                      "'DeleteMe' chat never disappeared after confirmed deletion")
    }

    func test_swipeToDelete_cancel_keepsChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-keychain"] + baseArgs
        app.launch()
        defer { app.terminate() }

        let create = CreateGroupScreen(app: app)
        create.open()
        create.typeName("KeepMe")
        create.tapNext()
        create.tapCreate()
        XCTAssertTrue(create.waitForSuccess(),
                      "Founder group creation never reached the success screen")
        create.tapDone()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'KeepMe'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "'KeepMe' chat never appeared on the Chats list")

        row.swipeLeft()
        let deleteAction = app.buttons["Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5),
                      "swipe Delete action never appeared")
        deleteAction.tap()

        // The dialog is up (its destructive button exists).
        let dialog = app.sheets["Delete this chat?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5),
                      "delete confirmation dialog never appeared")
        // The confirmationDialog's Cancel button isn't exposed in the
        // a11y tree on iOS 26, so dismiss by tapping the dimmed scrim
        // outside the dialog — equivalent to the Cancel action.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5),
                      "delete confirmation dialog never dismissed on cancel")

        // Cancelled → the chat is still there.
        XCTAssertTrue(app.staticTexts["KeepMe"].waitForExistence(timeout: 5),
                      "'KeepMe' chat must survive a cancelled delete")
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
