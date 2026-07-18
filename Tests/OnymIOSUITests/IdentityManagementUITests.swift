import XCTest

/// Multi-identity coverage against the unified Settings identity carousel
/// (which replaced the Identities list + detail screens): the carousel
/// shows every identity's invite QR, adds a new one from its last page,
/// switches active by swiping, and deletes from a per-page type-to-confirm.
///
/// The fresh launch arguments (`--reset-keychain --mock-biometric`)
/// guarantee one auto-bootstrapped identity at start.
final class IdentityManagementUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// 1) Settings shows the identity carousel with the bootstrapped
    /// identity marked ACTIVE.
    func test_carousel_showsBootstrappedIdentityAsActive() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.tapSettingsTab()
        // The active identity's page renders an ACTIVE badge — proof the
        // carousel loaded with the bootstrapped identity active.
        XCTAssertTrue(app.staticTexts["ACTIVE"].waitForExistence(timeout: 5),
                      "bootstrapped identity's ACTIVE badge never appeared in the carousel")
    }

    /// 2) Add Identity from the carousel's last page → new alias appears.
    func test_addIdentity_viaCarousel_appears() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.addIdentityViaCarousel(name: "Work")

        let workAlias = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Work'")
        ).firstMatch
        XCTAssertTrue(workAlias.waitForExistence(timeout: 8),
                      "newly-added 'Work' identity never appeared in the carousel")
    }

    /// 3) Picker on Chats switches identities; nav title flips. (Seeds the
    /// second identity via the carousel.)
    func test_chatsPicker_switchesActiveIdentity_titleFlips() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.addIdentityViaCarousel(name: "Work")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Work'"))
                .firstMatch.waitForExistence(timeout: 8)
        )

        let chats = ChatsScreen(app: app)
        chats.tapChatsTab()
        chats.tapPicker()
        let workMenuItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Work'")
        ).firstMatch
        XCTAssertTrue(workMenuItem.waitForExistence(timeout: 5),
                      "Work entry never appeared in the picker menu")
        workMenuItem.tap()

        let title = chats.navTitle("Work")
        XCTAssertTrue(title.waitForExistence(timeout: 5),
                      "Chats nav title never flipped to 'Work' after picker selection")
    }

    /// 4) Delete from the carousel — the visible page's Delete opens the
    /// name-confirm gate; confirming removes the identity.
    func test_deleteIdentity_viaCarousel_nameConfirmGate() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.addIdentityViaCarousel(name: "Work")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Work'"))
                .firstMatch.waitForExistence(timeout: 8)
        )

        // The carousel is on the just-added "Work" page — tap its Delete.
        let deleteButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'identity.delete.'")
        ).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5),
                      "carousel Delete action never appeared")
        deleteButton.tap()

        // Type-to-confirm gate (reused RemoveIdentitySheet).
        let confirmField = app.textFields["remove_identity.confirm_field"]
        XCTAssertTrue(confirmField.waitForExistence(timeout: 5),
                      "remove-identity confirm field never appeared")
        confirmField.tap()
        confirmField.typeText("Work")

        let removeButton = app.buttons["remove_identity.remove_button"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: removeButton
        )
        XCTAssertEqual(.completed, XCTWaiter.wait(for: [enabled], timeout: 5),
                       "Remove button never enabled after typing the correct name")
        removeButton.tap()

        // The "Work" alias is gone from the carousel.
        let workAlias = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Work'")
        ).firstMatch
        XCTAssertTrue(workAlias.waitForNonExistence(timeout: 5),
                      "'Work' identity never disappeared after confirmed removal")
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
