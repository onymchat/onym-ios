import XCTest

/// End-to-end UI tests for Settings → Anchors. The UITest fake
/// (`UITestContractsManifestFetcher`) ships a 2-release fixture with
/// testnet contracts only, so the Mainnet row always renders disabled
/// and Testnet drilling-down works for every governance type.
final class AnchorsUITests: XCTestCase {

    /// When the manifest publishes no Mainnet contracts, the Mainnet row
    /// renders disabled (no NavigationLink) while Testnet stays tappable.
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
