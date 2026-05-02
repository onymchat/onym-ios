import XCTest

/// End-to-end UI tests for Settings → Anchors. The UITest fake
/// (`UITestContractsManifestFetcher`) ships a 2-release fixture with
/// testnet contracts only, so the Mainnet row always renders disabled
/// and Testnet drilling-down works for every governance type.
final class AnchorsUITests: XCTestCase {

    func test_drilldown_pickVersion_thenResetToDefault() throws {
        let app = AppLauncher.launchFresh()
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.waitForReady())
        settings.tapAnchors()

        let root = AnchorsRootScreen(app: app)
        XCTAssertTrue(root.waitForReady())
        root.tapNetwork("testnet")

        let network = AnchorsNetworkScreen(app: app)
        XCTAssertTrue(network.waitForReady())
        network.tapType("anarchy")

        let version = AnchorsVersionScreen(app: app)
        XCTAssertTrue(version.waitForReady())

        // Initially no explicit selection → Reset button hidden.
        XCTAssertFalse(version.resetButton.exists,
                       "Reset must not appear before the user picks a version")

        // Pick the older release explicitly (default-to-latest would
        // otherwise resolve to v0.0.2). The button auto-pops back via
        // dismiss(), but if the dismiss races with the test we'd
        // assert state on the popped network screen instead — handle
        // both by waiting on whichever appears first.
        version.tapVersion("v0.0.1")

        // After the tap, the explicit selection lands. Reset becomes
        // visible if we're still on the version screen; otherwise we
        // popped back to the network screen and need to drill in
        // again to see Reset.
        let onVersionScreen = version.resetButton.waitForExistence(timeout: 2)
        if !onVersionScreen {
            XCTAssertTrue(network.waitForReady(),
                          "expected to be back on network screen if dismiss popped")
            network.tapType("anarchy")
            XCTAssertTrue(version.waitForReady())
            XCTAssertTrue(version.resetButton.waitForExistence(timeout: 3),
                          "Reset to Default must show after the user has an explicit selection")
        }

        // Tap Reset — clears the explicit selection. Reset itself
        // should disappear (its section is gated on
        // `hasExplicitSelection`).
        version.tapReset()
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: version.resetButton
        )
        // If dismiss fires after Reset, the button disappears because
        // we left the screen — either way exists==false eventually.
        XCTAssertEqual(.completed, XCTWaiter.wait(for: [expectation], timeout: 3),
                       "Reset to Default must hide once the explicit selection is cleared")
    }

    func test_mainnet_isDisabled_whenNoContractsPublished() throws {
        let app = AppLauncher.launchFresh()
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.waitForReady())
        settings.tapAnchors()

        let root = AnchorsRootScreen(app: app)
        XCTAssertTrue(root.waitForReady())

        // Mainnet renders as a disabled row (no NavigationLink) because
        // the UITest fixture publishes testnet contracts only.
        XCTAssertTrue(root.disabledNetworkRow("public").waitForExistence(timeout: 3),
                      "Mainnet must render disabled when no manifest entries exist for it")
        // The active row still works.
        XCTAssertTrue(root.networkRow("testnet").exists)
    }
}
