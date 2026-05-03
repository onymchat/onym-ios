import XCTest

/// Page object for the Chats tab — the app's default tab post-PR-30.
/// Multi-identity (PR #56) added a toolbar leading picker; this page
/// object exposes both the tab itself and that picker.
struct ChatsScreen {
    let app: XCUIApplication

    /// Mirror of `SettingsScreen.settingsTab` — iOS 26's Liquid Glass
    /// `TabView` exposes tab items inconsistently. Try a few likely
    /// queries.
    var chatsTab: XCUIElement {
        let candidates: [String] = ["Chats", "Чаты"]
        for label in candidates {
            let tabBarMatch = app.tabBars.buttons[label]
            if tabBarMatch.exists { return tabBarMatch }
        }
        for label in candidates {
            let topLevelMatch = app.buttons[label]
            if topLevelMatch.exists { return topLevelMatch }
        }
        // Fall back to index 0 of the tab bar (Chats=0, Settings=1).
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, tabBar.buttons.count >= 1 {
            return tabBar.buttons.element(boundBy: 0)
        }
        return app.buttons["Chats"]
    }

    /// Top-bar leading picker — disabled when only one identity exists.
    var picker: XCUIElement { app.buttons["identity_picker.menu"] }

    /// Menu row inside the picker for the identity whose UUID is
    /// `idString`. Identifier shape: `identity_picker.row.<UUID>`.
    func pickerRow(forID idString: String) -> XCUIElement {
        app.buttons["identity_picker.row.\(idString)"]
    }

    /// Navigation title — flips to the active identity's name when
    /// any identity is selected.
    func navTitle(_ text: String) -> XCUIElement {
        app.staticTexts[text]
    }

    func tapChatsTab(timeout: TimeInterval = 5) {
        let element = chatsTab
        if !element.waitForExistence(timeout: timeout) {
            XCTFail("Chats tab never appeared. Hierarchy:\n\(app.debugDescription)")
            return
        }
        element.tap()
    }

    func tapPicker() {
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "identity picker menu never appeared on the Chats tab")
        picker.tap()
    }

    func selectIdentity(idString: String) {
        let row = pickerRow(forID: idString)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "identity picker row \(idString) never appeared")
        row.tap()
    }
}
