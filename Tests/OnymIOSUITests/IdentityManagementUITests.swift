import XCTest

/// End-to-end coverage of the multi-identity surface that landed in
/// PR #56 (the 5-PR multi-identity stack: keychain → repository →
/// group filter → transport fan-out → UI).
///
/// The fresh launch arguments (`--reset-keychain --mock-biometric`)
/// guarantee one auto-bootstrapped identity at start; tests build
/// on top of that single starting point.
final class IdentityManagementUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// 1) Settings → Identities row → list appears with the bootstrapped
    /// identity marked Active.
    func test_identitiesList_showsBootstrappedIdentityAsActive() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.tapIdentities()

        let identities = IdentitiesScreen(app: app)
        XCTAssertTrue(identities.waitForReady(),
                      "Identities list never loaded")
        XCTAssertEqual(identities.rows.count, 1,
                       "fresh install should have exactly one auto-bootstrapped identity")
    }

    /// 2) Add Identity sheet → name in → submit → list grows by one.
    func test_addIdentity_sheetSubmits_growsList() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.tapIdentities()
        let identities = IdentitiesScreen(app: app)
        _ = identities.waitForReady()

        identities.tapAdd()
        identities.typeAddName("Work")
        identities.tapAddSubmit()

        // The sheet closes async after the repository's add(); poll
        // the row count until the new identity is observable.
        let workRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Work'")
        ).firstMatch
        XCTAssertTrue(workRow.waitForExistence(timeout: 5),
                      "newly-added 'Work' identity never appeared in the list")
        XCTAssertEqual(identities.rows.count, 2,
                       "list should contain the bootstrapped identity + 'Work'")
    }

    /// 3) Picker on Chats switches identities; nav title flips.
    func test_chatsPicker_switchesActiveIdentity_titleFlips() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        // Seed a second identity so the picker becomes interactive.
        let settings = SettingsScreen(app: app)
        settings.tapIdentities()
        let identities = IdentitiesScreen(app: app)
        _ = identities.waitForReady()
        identities.tapAdd()
        identities.typeAddName("Work")
        identities.tapAddSubmit()
        // Wait for the row before navigating away.
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Work'"))
                .firstMatch.waitForExistence(timeout: 5)
        )

        // Drive the picker.
        let chats = ChatsScreen(app: app)
        chats.tapChatsTab()

        // The picker row is identified by `identity_picker.row.<uuid>`,
        // but we don't know the uuid here — match the menu row by
        // label instead.
        chats.tapPicker()
        let workMenuItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Work'")
        ).firstMatch
        XCTAssertTrue(workMenuItem.waitForExistence(timeout: 5),
                      "Work entry never appeared in the picker menu")
        workMenuItem.tap()

        // Nav title becomes the active identity's name.
        let title = chats.navTitle("Work")
        XCTAssertTrue(title.waitForExistence(timeout: 5),
                      "Chats nav title never flipped to 'Work' after picker selection")
    }

    /// 4) Restore from recovery phrase — green sibling card pushes
    /// `RestoreIdentityView`, BIP39 validity gates the Restore button,
    /// happy-path adds an identity alongside the bootstrap and pops back
    /// (issue #99). The exhaustive valid/invalid branches are covered
    /// by `IdentitiesFlowTests` at the view-model level; this test
    /// focuses on the wiring: card → push → submit → pop → row added.
    func test_restoreIdentity_validPhrase_addsAlongsideAndPopsBack() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.tapIdentities()
        let identities = IdentitiesScreen(app: app)
        _ = identities.waitForReady()
        XCTAssertEqual(identities.rows.count, 1)

        identities.tapRestore()

        // Sanity: the Restore screen is up and the CTA starts disabled
        // (empty phrase fails BIP39 validation).
        XCTAssertTrue(identities.restorePhraseField.waitForExistence(timeout: 5),
                      "Restore phrase field never appeared after tapping Restore card")
        XCTAssertTrue(identities.restoreSubmitButton.waitForExistence(timeout: 5))
        XCTAssertFalse(identities.restoreSubmitButton.isEnabled,
                       "Restore button must start disabled (empty phrase)")

        // Canonical BIP39 test vector — 16 zero-bytes entropy. Valid
        // checksum (SHA256(0x0…0)[0] >> 4 = 0x3 → trailing word "about").
        // This is the same vector Android's RestoreIdentityScreen test
        // uses, so a phrase that passes here will also restore on
        // Android — the cross-platform interop guarantee.
        let validPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        identities.typeRestorePhrase(validPhrase)

        XCTAssertTrue(identities.restoreHintValid.waitForExistence(timeout: 3),
                      "valid hint never appeared for canonical BIP39 vector")
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(
            predicate: enabledPredicate,
            object: identities.restoreSubmitButton
        )
        XCTAssertEqual(.completed, XCTWaiter.wait(for: [expectation], timeout: 5),
                       "Restore button never enabled after typing a valid phrase")

        identities.restoreSubmitButton.tap()

        // After success the screen pops and the identity list grows by
        // one — bootstrap survives, restored identity is now listed.
        // Default alias for the new slot is "Identity 2" (slot 1 is the
        // bootstrap, named "Identity").
        XCTAssertTrue(identities.addButton.waitForExistence(timeout: 5),
                      "did not return to Identities after Restore")
        let restoredRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Identity 2'")
        ).firstMatch
        XCTAssertTrue(restoredRow.waitForExistence(timeout: 5),
                      "restored identity row never appeared on Identities — restore didn't add a sibling")
    }

    /// 5) Remove flow — name-confirm gate blocks until exact match,
    /// list shrinks back after confirmed removal.
    func test_removeIdentity_nameConfirmGate_blocksThenAllows() throws {
        let app = AppLauncher.launchFresh()
        defer { app.terminate() }

        // Add a "Work" identity first.
        let settings = SettingsScreen(app: app)
        settings.tapIdentities()
        let identities = IdentitiesScreen(app: app)
        _ = identities.waitForReady()
        identities.tapAdd()
        identities.typeAddName("Work")
        identities.tapAddSubmit()

        let workRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Work'")
        ).firstMatch
        XCTAssertTrue(workRow.waitForExistence(timeout: 5))

        // Swipe + tap Remove.
        identities.swipeRemove(named: "Work")

        // Wrong text — Remove button stays disabled.
        identities.typeNameToConfirm("nope")
        XCTAssertTrue(identities.removeButton.waitForExistence(timeout: 5))
        XCTAssertFalse(identities.removeButton.isEnabled,
                       "Remove button must stay disabled until the name matches")

        // Clear + correct text → button enables.
        identities.removeConfirmField.tap()
        identities.removeConfirmField.press(forDuration: 1.0)
        if app.menuItems["Select All"].exists {
            app.menuItems["Select All"].tap()
        }
        identities.removeConfirmField.typeText(XCUIKeyboardKey.delete.rawValue)
        identities.removeConfirmField.typeText("Work")

        // Poll until the button enables — SwiftUI's `.disabled` flips
        // on the next state push.
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(
            predicate: enabledPredicate,
            object: identities.removeButton
        )
        XCTAssertEqual(.completed, XCTWaiter.wait(for: [expectation], timeout: 5),
                       "Remove button never enabled after typing the correct name")

        identities.tapRemove()

        // List shrinks back to one row.
        XCTAssertTrue(
            workRow.waitForNonExistence(timeout: 5),
            "'Work' row never disappeared after confirmed removal"
        )
        XCTAssertEqual(identities.rows.count, 1,
                       "list should shrink back to the bootstrapped identity")
    }
}

private extension XCUIElement {
    /// Polls until the element is no longer present. XCUI lacks a
    /// built-in `waitForNonExistence`, but the inverse predicate works.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: self
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
