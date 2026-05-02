import XCTest

/// Page object for Anchors → \<Network\> → \<Type\> — the leaf
/// drill-down listing all releases that have a contract for the
/// (network, type) being picked, newest-first. Tap a row to select;
/// pop back is automatic. "Reset to Default" appears only when the
/// user has an explicit selection.
struct AnchorsVersionScreen {
    let app: XCUIApplication

    func versionRow(_ release: String) -> XCUIElement {
        firstMatching("anchors.version.\(release)")
    }

    var resetButton: XCUIElement {
        app.buttons["anchors.version.reset"]
    }

    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        // Wait for at least the v0.0.2 row (the UITest fixture's newest
        // release; always present for the .testnet × .anarchy pair the
        // happy-path test exercises).
        versionRow("v0.0.2").waitForExistence(timeout: timeout)
    }

    func tapVersion(_ release: String) {
        let row = versionRow(release)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "expected a version row for \(release)")
        row.tap()
    }

    func tapReset() {
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5),
                      "Reset to Default button never appeared (only shown when user has an explicit selection)")
        resetButton.tap()
    }

    private func firstMatching(_ identifier: String) -> XCUIElement {
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query[identifier]
            if element.exists { return element }
        }
        return app.buttons[identifier]
    }
}
