import XCTest

/// Page object for the Settings tab — the app's root screen.
struct SettingsScreen {
    let app: XCUIApplication

    var backupRow: XCUIElement {
        app.buttons["settings.backup_recovery_phrase_row"]
    }

    @discardableResult
    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        backupRow.waitForExistence(timeout: timeout)
    }

    func tapBackupRecoveryPhrase() {
        XCTAssertTrue(backupRow.waitForExistence(timeout: 5),
                      "settings backup row never appeared")
        backupRow.tap()
    }
}
