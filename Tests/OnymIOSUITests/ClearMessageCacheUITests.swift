import XCTest

/// Covers Settings → DATA → "Clear Local Message Cache" — the section
/// moved out of Privacy & Encryption onto the Settings home (above
/// About) — and its two-step ("double") confirmation: the row opens a
/// first alert explaining what's lost + that it can't be re-downloaded,
/// whose confirm opens a final are-you-sure, whose confirm runs the wipe
/// and dismisses.
///
/// The actual deletion (all messages, chats preserved) is unit-tested in
/// `MessageRepositoryTests.test_removeAll_…`; this asserts the moved UI
/// and the double-confirm gate.
final class ClearMessageCacheUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_clearMessages_requiresTwoConfirmations_thenDismisses() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.tapClearMessages()

        // First gate appears.
        let clearButton = app.buttons["Clear Messages"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5),
                      "first confirmation alert never appeared")
        // One confirmation isn't enough — the final gate isn't shown yet.
        XCTAssertFalse(app.buttons["Delete All Messages"].exists,
                       "final confirmation must not appear before the first is confirmed")
        clearButton.tap()

        // Final gate appears after the first confirm.
        let deleteButton = app.buttons["Delete All Messages"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5),
                      "final confirmation alert never appeared")
        deleteButton.tap()

        // The alert dismisses and the app is still alive (wipe ran).
        XCTAssertTrue(deleteButton.waitForNonExistence(timeout: 5),
                      "final confirmation alert never dismissed")
        XCTAssertEqual(app.state, .runningForeground)
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
