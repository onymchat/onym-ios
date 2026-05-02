import XCTest

/// Page object for Anchors → \<Network\> — the second-level drill-
/// down listing the five governance types for the chosen network.
struct AnchorsNetworkScreen {
    let app: XCUIApplication

    /// Governance-type row when contracts are available (NavigationLink).
    func typeRow(_ raw: String) -> XCUIElement {
        firstMatching("anchors.type.\(raw)")
    }

    /// Governance-type row when no contract exists (plain text).
    func disabledTypeRow(_ raw: String) -> XCUIElement {
        firstMatching("anchors.type.\(raw).disabled")
    }

    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        typeRow("anarchy").waitForExistence(timeout: timeout)
    }

    func tapType(_ raw: String) {
        let row = typeRow(raw)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "expected an enabled type row for \(raw)")
        row.tap()
    }

    private func firstMatching(_ identifier: String) -> XCUIElement {
        for query in [app.buttons, app.cells, app.otherElements, app.staticTexts] {
            let element = query[identifier]
            if element.exists { return element }
        }
        return app.buttons[identifier]
    }
}
