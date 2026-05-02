import XCTest

/// Page object for the Settings → Relayer screen. Tests configure the
/// relayer list (auto-populated from the UITest fake fetcher on first
/// launch), pick a primary, switch strategy, etc.
struct RelayerSettingsScreen {
    let app: XCUIApplication

    /// SwiftUI's segmented `Picker` doesn't expose its `accessibilityIdentifier`
    /// as a queryable container — only the segment buttons are
    /// individually addressable, by their localised display name. Tests
    /// pass the en label they want; under a non-en locale, swap to a
    /// localised lookup.
    func strategySegment(label: String) -> XCUIElement {
        app.buttons[label]
    }

    var primarySegment: XCUIElement { strategySegment(label: "Primary") }
    var randomSegment: XCUIElement { strategySegment(label: "Random") }

    /// Configured-list row identifier is `relayer.configured.<URL>`.
    /// SwiftUI's accessibility flattening promoted this row to a
    /// Button (with the inner star's label "Favorite"), so query the
    /// buttons collection.
    func configuredRow(url: String) -> XCUIElement {
        firstMatching("relayer.configured.\(url)")
    }

    /// Per-row star button id. Tap to mark that row primary. Reachable
    /// because `.accessibilityElement(children: .contain)` on the row
    /// keeps inner elements individually queryable.
    func primaryStar(url: String) -> XCUIElement {
        app.buttons["relayer.configured.primary.\(url)"]
    }

    /// "Add from Published List" row id.
    func addKnownRow(url: String) -> XCUIElement {
        firstMatching("relayer.add.known.\(url)")
    }

    var customField: XCUIElement {
        app.textFields["relayer.add.custom.field"]
    }

    var customAddButton: XCUIElement {
        app.buttons["relayer.add.custom.button"]
    }

    /// Wait for the screen to be ready by waiting on a known segment.
    func waitForReady(timeout: TimeInterval = 5) -> Bool {
        randomSegment.waitForExistence(timeout: timeout)
    }

    /// Tap the segment with the given label.
    func tapStrategy(label: String) {
        let segment = strategySegment(label: label)
        XCTAssertTrue(segment.waitForExistence(timeout: 5),
                      "strategy segment '\(label)' never appeared")
        segment.tap()
    }

    /// Swipe left on the row at `url` to reveal the system Delete
    /// affordance, then tap it.
    func swipeToDelete(url: String) {
        let row = configuredRow(url: url)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "expected a configured row for \(url) before swiping")
        row.swipeLeft()
        let deleteButton = app.buttons["Delete"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3),
                      "system Delete button never appeared after swipe")
        deleteButton.tap()
    }

    private func firstMatching(_ identifier: String) -> XCUIElement {
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query[identifier]
            if element.exists { return element }
        }
        return app.buttons[identifier]
    }
}
