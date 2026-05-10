import XCTest

/// Page object for Settings → Identities (and the Add / Remove sheets
/// it presents). Mirrors the SettingsScreen / RelayerSettingsScreen
/// shape — XCUIElement properties + `waitForReady()` + per-action
/// `tap*` helpers.
struct IdentitiesScreen {
    let app: XCUIApplication

    // MARK: - List screen

    var addButton: XCUIElement {
        // The button label is "Add Identity" but the accessibility id
        // (`identities.add_button`) is the stable handle.
        firstMatching("identities.add_button")
    }

    /// Sibling action card that pushes `RestoreIdentityView` (issue #99).
    var restoreButton: XCUIElement {
        firstMatching("identities.restore_button")
    }

    /// Row for the identity whose summary `id` (an UUID string)
    /// matches. Identifier shape: `identities.row.<UUID>`.
    func row(forID idString: String) -> XCUIElement {
        firstMatching("identities.row.\(idString)")
    }

    /// The Active badge that decorates the currently-selected
    /// identity's row. `idString` is the same UUID as `row(forID:)`.
    func activeBadge(forID idString: String) -> XCUIElement {
        app.staticTexts["identities.active_badge.\(idString)"]
    }

    /// Every identity row currently visible. Order is keychain-internal
    /// (effectively undefined); use `count` for cardinality assertions.
    var rows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'identities.row.'"
        ))
    }

    @discardableResult
    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        addButton.waitForExistence(timeout: timeout)
    }

    func tapAdd() {
        XCTAssertTrue(addButton.waitForExistence(timeout: 5),
                      "Add Identity button never appeared")
        addButton.tap()
    }

    /// Swipe-to-reveal the destructive Remove action on the row whose
    /// staticText label matches `name`. Triggers the confirm sheet.
    func swipeRemove(named name: String) {
        // Find the row whose visible label includes `name`. Rows
        // expose a stable `identities.row.<uuid>` id but we usually
        // don't know the uuid in the test — match by the visible name
        // instead.
        let predicate = NSPredicate(format: "label CONTAINS %@", name)
        let row = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "row for identity '\(name)' never appeared")
        row.swipeLeft()
        // The destructive swipe action surfaces as a system Button
        // labeled "Remove" — same token the swipeActions(...) closure
        // produces.
        let removeAction = app.buttons["Remove"]
        XCTAssertTrue(removeAction.waitForExistence(timeout: 5),
                      "swipe Remove action never appeared")
        removeAction.tap()
    }

    // MARK: - Add Identity sheet

    var addNameField: XCUIElement { app.textFields["add_identity.name_field"] }
    var addSubmitButton: XCUIElement { app.buttons["add_identity.submit_button"] }

    func typeAddName(_ name: String) {
        XCTAssertTrue(addNameField.waitForExistence(timeout: 5),
                      "Add Identity name field never appeared")
        addNameField.tap()
        addNameField.typeText(name)
    }

    func tapAddSubmit() {
        XCTAssertTrue(addSubmitButton.waitForExistence(timeout: 5),
                      "Add Identity submit button never appeared")
        addSubmitButton.tap()
    }

    // MARK: - Restore Identity screen (issue #99)

    var restorePhraseField: XCUIElement {
        // SwiftUI's TextEditor renders as a textView in XCUI.
        app.textViews["restore_identity.phrase_field"]
    }
    var restoreAliasField: XCUIElement {
        app.textFields["restore_identity.alias_field"]
    }
    var restoreSubmitButton: XCUIElement {
        firstMatching("restore_identity.submit_button")
    }
    var restoreHintValid: XCUIElement {
        app.staticTexts["restore_identity.hint_valid"]
    }
    var restoreHintInvalid: XCUIElement {
        app.staticTexts["restore_identity.hint_invalid"]
    }

    func tapRestore() {
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 5),
                      "Restore from recovery phrase button never appeared")
        restoreButton.tap()
    }

    func typeRestorePhrase(_ phrase: String) {
        XCTAssertTrue(restorePhraseField.waitForExistence(timeout: 5),
                      "Restore phrase field never appeared")
        restorePhraseField.tap()
        restorePhraseField.typeText(phrase)
    }

    // MARK: - Remove Identity confirm sheet

    var removeConfirmField: XCUIElement {
        app.textFields["remove_identity.confirm_field"]
    }

    var removeButton: XCUIElement {
        app.buttons["remove_identity.remove_button"]
    }

    func typeNameToConfirm(_ text: String) {
        XCTAssertTrue(removeConfirmField.waitForExistence(timeout: 5),
                      "Remove Identity confirm field never appeared")
        removeConfirmField.tap()
        // Clear any prior value first by selecting all + deleting,
        // since the field reuses across taps within one sheet open.
        removeConfirmField.typeText(text)
    }

    func tapRemove() {
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5),
                      "Remove Identity remove button never appeared")
        removeButton.tap()
    }

    // MARK: - Private

    /// SwiftUI's NavigationLink + Buttons render as different
    /// XCUIElement types depending on iOS version + form context.
    /// Mirrors the helper in `SettingsScreen`.
    private func firstMatching(_ identifier: String) -> XCUIElement {
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query[identifier]
            if element.exists { return element }
        }
        return app.buttons[identifier]
    }
}
