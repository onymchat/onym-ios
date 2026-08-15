import XCTest

/// Page object for Settings → Discovery Providers and its add/TOFU
/// sheet. Only meaningful when the app was launched with
/// `--ui-discovery` (see `AppLauncher.launchFresh(discovery:)`) —
/// without it the DISCOVERY section doesn't exist at all.
struct DiscoverySettingsScreen {
    let app: XCUIApplication

    /// The seeded default source's providerId — the accessibility ids
    /// below embed it (`settings.discovery.source.<providerId>`).
    static let defaultProviderId = "onym:component:onym-discovery"

    // MARK: - Navigation

    /// Settings → DISCOVERY → Discovery Providers row. Sits below the
    /// fold on the Settings page, so scroll it into view first
    /// (bounded, same pattern as `SettingsScreen.tapClearMessages`).
    func open(maxSwipes: Int = 8) {
        SettingsScreen(app: app).tapSettingsTab()
        let row = discoveryRow
        var n = 0
        while !(row.exists && row.isHittable) && n < maxSwipes {
            app.swipeUp()
            n += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "settings discovery row never appeared")
        row.tap()
    }

    var discoveryRow: XCUIElement {
        firstMatching("settings.discovery_row")
    }

    // MARK: - Sources list

    /// The seeded default source's row.
    var defaultSourceRow: XCUIElement {
        firstMatching("settings.discovery.source.\(Self.defaultProviderId)")
    }

    /// "Confirm…" on the unconfirmed seeded default (opens the TOFU
    /// sheet pre-filled with the source's manifest URL).
    var confirmSourceButton: XCUIElement {
        app.buttons["settings.discovery.source.\(Self.defaultProviderId).confirm"]
    }

    // MARK: - Add / TOFU sheet

    /// The operator-key fingerprint on the TOFU confirmation step.
    var fingerprint: XCUIElement {
        app.staticTexts["settings.discovery.add.fingerprint"]
    }

    /// "Pin Key & Add Provider".
    var pinConfirmButton: XCUIElement {
        app.buttons["settings.discovery.add.confirm"]
    }

    /// The "Provider added" done state. The identifier sits on a
    /// SwiftUI `VStack`, whose element type varies by iOS version —
    /// match any descendant by identifier.
    var addDone: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "settings.discovery.add.done")
            .firstMatch
    }

    /// The source row's verified-entry count line ("1 catalog entry").
    /// Matched by CONTAINS: the count string goes through automatic
    /// grammar agreement (`^[…](inflect: true)`), and under the UI-test
    /// language override the label can surface as the raw inflection
    /// markup — the count + noun substring is the stable part.
    func entryCountText(_ count: Int) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "\(count) catalog entr")
        ).firstMatch
    }

    /// Sheet toolbar dismiss ("Cancel" / "Done").
    var dismissSheetButton: XCUIElement {
        app.buttons["settings.discovery.add.dismiss"]
    }

    /// SwiftUI renders rows/links as different XCUIElement types
    /// depending on iOS version + container — try the likely queries
    /// (same helper shape as `SettingsScreen.firstMatching`).
    private func firstMatching(_ identifier: String) -> XCUIElement {
        for query in [app.buttons, app.cells, app.otherElements] {
            let element = query[identifier]
            if element.exists { return element }
        }
        return app.buttons[identifier]
    }
}
