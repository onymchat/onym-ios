import XCTest

/// Page object for the Settings tab — the app's root screen.
struct SettingsScreen {
    let app: XCUIApplication

    var backupRow: XCUIElement {
        app.buttons["settings.backup_recovery_phrase_row"]
    }

    /// Network → Relayer NavigationLink. Lives behind a chevron row.
    var relayerRow: XCUIElement {
        firstMatching("settings.relayer_row")
    }

    /// Network → Anchors NavigationLink.
    var anchorsRow: XCUIElement {
        firstMatching("settings.anchors_row")
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

    func tapRelayer() {
        XCTAssertTrue(relayerRow.waitForExistence(timeout: 5),
                      "settings relayer row never appeared")
        relayerRow.tap()
    }

    func tapAnchors() {
        XCTAssertTrue(anchorsRow.waitForExistence(timeout: 5),
                      "settings anchors row never appeared")
        anchorsRow.tap()
    }

    /// SwiftUI's NavigationLink renders as different XCUIElement types
    /// depending on iOS version + form context. Try a few likely
    /// queries and return the first that exists.
    private func firstMatching(_ identifier: String) -> XCUIElement {
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query[identifier]
            if element.exists { return element }
        }
        // Fall through with a button query so the eventual
        // waitForExistence assertion fires with a useful name.
        return app.buttons[identifier]
    }
}
