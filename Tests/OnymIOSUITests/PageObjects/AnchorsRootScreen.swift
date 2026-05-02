import XCTest

/// Page object for the Settings → Anchors root screen. Two rows
/// (Testnet / Mainnet); Mainnet renders as text-only when no manifest
/// entries exist for it. The UITest fixture has testnet contracts
/// only, so Mainnet is always disabled.
struct AnchorsRootScreen {
    let app: XCUIApplication

    /// Network row when contracts ARE published for it (NavigationLink).
    func networkRow(_ raw: String) -> XCUIElement {
        firstMatching("anchors.network.\(raw)")
    }

    /// Network row when NO contracts are published for it (plain text,
    /// not tappable).
    func disabledNetworkRow(_ raw: String) -> XCUIElement {
        firstMatching("anchors.network.\(raw).disabled")
    }

    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        networkRow("testnet").waitForExistence(timeout: timeout)
    }

    func tapNetwork(_ raw: String) {
        let row = networkRow(raw)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "expected an enabled network row for \(raw)")
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
