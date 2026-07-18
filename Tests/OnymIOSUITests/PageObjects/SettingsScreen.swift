import XCTest

/// Page object for the Settings tab. Settings is no longer the app's
/// root screen (Chats is the default tab — see RootView), so every
/// public method first taps the Settings tab via its stable
/// `root_tab.settings` accessibility identifier. Idempotent: tapping
/// a tab that's already selected is a no-op.
struct SettingsScreen {
    let app: XCUIApplication

    /// iOS 26's Liquid Glass `TabView` exposes tab items inconsistently:
    /// sometimes via `app.tabBars.buttons[localizedLabel]`, sometimes
    /// only via top-level `app.buttons[localizedLabel]`, and the
    /// `.accessibilityIdentifier` modifier doesn't propagate from
    /// `Tab(...)`. Try a few likely shapes and return the first that
    /// exists. Localized labels are required because `Tab("Settings",
    /// systemImage:, …)` uses the displayed string as its accessibility
    /// label after going through iOS's localization.
    var settingsTab: XCUIElement {
        let candidates: [String] = ["Settings", "Настройки"]
        for label in candidates {
            let tabBarMatch = app.tabBars.buttons[label]
            if tabBarMatch.exists { return tabBarMatch }
        }
        for label in candidates {
            let topLevelMatch = app.buttons[label]
            if topLevelMatch.exists { return topLevelMatch }
        }
        // Fall back to index 1 of the tab bar (Chats=0, Settings=1;
        // Search has role: .search and isn't on the regular strip).
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, tabBar.buttons.count >= 2 {
            return tabBar.buttons.element(boundBy: 1)
        }
        // Last resort — return the English label so the eventual
        // failure message is intelligible.
        return app.buttons["Settings"]
    }

    var backupRow: XCUIElement {
        app.buttons["settings.backup_recovery_phrase_row"]
    }

    /// Swipe the carousel left once. A paged `TabView` doesn't expose its
    /// scroll view as a queryable element, so we drag by coordinates across
    /// the carousel's vertical band (just under the "Settings" title, over
    /// the QR) — element-free and reliable.
    func swipeCarouselLeft() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.30))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.30))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Swipe the carousel left until the "add identity" page (with its
    /// inline name field) is on screen. Bounded so a missing page can't
    /// spin forever.
    func swipeCarouselToAddPage(maxSwipes: Int = 8) {
        tapSettingsTab()
        let addField = app.textFields["identity.add.name_field"]
        var n = 0
        while !addField.exists && n < maxSwipes {
            swipeCarouselLeft()
            n += 1
        }
    }

    /// Add a new identity through the carousel's add page.
    func addIdentityViaCarousel(name: String) {
        swipeCarouselToAddPage()
        let field = app.textFields["identity.add.name_field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "carousel add-identity field never appeared")
        field.tap()
        field.typeText(name)
        app.buttons["identity.add.create_button"].tap()
    }

    /// Network → Relayer NavigationLink. Lives behind a chevron row.
    var relayerRow: XCUIElement {
        firstMatching("settings.relayer_row")
    }

    /// Network → Anchors NavigationLink.
    var anchorsRow: XCUIElement {
        firstMatching("settings.anchors_row")
    }

    /// Tap the Settings tab. Tests that need to assert tab-bar state
    /// before drilling into a row can call this directly; the per-row
    /// `tap*` methods already do so internally.
    func tapSettingsTab(timeout: TimeInterval = 5) {
        let element = settingsTab
        if !element.waitForExistence(timeout: timeout) {
            XCTFail(
                "Settings tab never appeared. Hierarchy:\n\(app.debugDescription)"
            )
            return
        }
        element.tap()
    }

    @discardableResult
    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        tapSettingsTab(timeout: timeout)
        return backupRow.waitForExistence(timeout: timeout)
    }

    func tapBackupRecoveryPhrase() {
        tapSettingsTab()
        XCTAssertTrue(backupRow.waitForExistence(timeout: 5),
                      "settings backup row never appeared")
        backupRow.tap()
    }

    func tapRelayer() {
        tapSettingsTab()
        XCTAssertTrue(relayerRow.waitForExistence(timeout: 5),
                      "settings relayer row never appeared")
        relayerRow.tap()
    }

    func tapAnchors() {
        tapSettingsTab()
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
