import XCTest

/// Page object for the Search tab. The tab uses `role: .search`, so it
/// sits in the system's bottom-right search slot rather than the regular
/// tab strip; the same "try a few queries" fallback the other tab page
/// objects use applies here too.
struct SearchScreen {
    let app: XCUIApplication

    var searchTab: XCUIElement {
        let candidates: [String] = ["Search", "Поиск"]
        for label in candidates {
            let tabBarMatch = app.tabBars.buttons[label]
            if tabBarMatch.exists { return tabBarMatch }
        }
        for label in candidates {
            let topLevelMatch = app.buttons[label]
            if topLevelMatch.exists { return topLevelMatch }
        }
        // Search's role-based slot is usually the last tab-bar button.
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, tabBar.buttons.count >= 1 {
            return tabBar.buttons.element(boundBy: tabBar.buttons.count - 1)
        }
        return app.buttons["Search"]
    }

    var searchField: XCUIElement { app.searchFields.firstMatch }

    func tapSearchTab(timeout: TimeInterval = 5) {
        let element = searchTab
        if !element.waitForExistence(timeout: timeout) {
            XCTFail("Search tab never appeared. Hierarchy:\n\(app.debugDescription)")
            return
        }
        element.tap()
    }

    /// Focus the search field and type a query.
    func search(for text: String) {
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "search field never appeared on the Search tab")
        searchField.tap()
        searchField.typeText(text)
    }

    /// A result row matched by the snippet text it renders.
    func result(containing snippet: String) -> XCUIElement {
        // NavigationLink rows surface as cells / buttons depending on
        // iOS; match whichever contains the snippet static text.
        let cell = app.cells.containing(.staticText, identifier: snippet).firstMatch
        if cell.exists { return cell }
        return app.staticTexts[snippet]
    }
}
