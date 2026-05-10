import XCTest

/// End-to-end UI tests for Settings → Relayer. The app's UITest mode
/// (`--ui-testing`) swaps in `UITestKnownRelayersFetcher` +
/// `UITestRelayerSelectionStore` so each launch starts from a clean
/// in-memory state and the GitHub fetch is replaced by a deterministic
/// fixture (the two `UITestKnownRelayersFetcher` constants).
///
/// Critically the auto-populate behaviour means the configured list is
/// pre-seeded on first launch — every test starts with both fixture
/// relayers already in `Configured` and strategy = Random.
final class RelayerSettingsUITests: XCTestCase {

    // Fixture URLs — duplicated from `UITestKnownRelayersFetcher` so
    // a rename forces a test fix here too (treat the IDs as cross-
    // bundle contract).
    private let testnetURL = "https://uitest-testnet-relayer.example"
    private let publicURL = "https://uitest-mainnet-relayer.example"

    // MARK: - first launch

    func test_firstLaunch_configuredListAutoPopulatedFromManifest() throws {
        let app = AppLauncher.launchFresh()
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.waitForReady())
        settings.tapRelayer()

        let relayer = RelayerSettingsScreen(app: app)
        XCTAssertTrue(relayer.waitForReady())

        XCTAssertTrue(relayer.configuredRow(url: testnetURL).waitForExistence(timeout: 5),
                      "first launch should auto-populate the testnet fixture")
        XCTAssertTrue(relayer.configuredRow(url: publicURL).exists,
                      "first launch should auto-populate the mainnet fixture too")
    }

    func test_firstLaunch_strategyDefaultsToRandom() throws {
        let app = AppLauncher.launchFresh()
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.waitForReady())
        settings.tapRelayer()

        let relayer = RelayerSettingsScreen(app: app)
        XCTAssertTrue(relayer.waitForReady())

        // Random segment is selected by default.
        XCTAssertTrue(relayer.randomSegment.isSelected,
                      "Random strategy must be selected by default after first-launch auto-populate")
    }

    // MARK: - mutators

    func test_setPrimary_thenSwitchToPrimary_persistsViaUI() throws {
        let app = AppLauncher.launchFresh()
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.waitForReady())
        settings.tapRelayer()

        let relayer = RelayerSettingsScreen(app: app)
        XCTAssertTrue(relayer.waitForReady())

        // Mark the testnet fixture as primary.
        let star = relayer.primaryStar(url: testnetURL)
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.tap()

        // Switch to Primary strategy via the segmented control.
        relayer.tapStrategy(label: "Primary")

        // Primary segment is now the selected one.
        XCTAssertTrue(relayer.primarySegment.isSelected)
    }

    func test_addCustomURL_appearsInConfigured() throws {
        let app = AppLauncher.launchFresh()
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.waitForReady())
        settings.tapRelayer()

        let relayer = RelayerSettingsScreen(app: app)
        XCTAssertTrue(relayer.waitForReady())

        let customURL = "https://my-custom-relayer.dev"

        XCTAssertTrue(relayer.customField.waitForExistence(timeout: 5))
        relayer.customField.tap()
        relayer.customField.typeText(customURL)
        relayer.customAddButton.tap()

        // Field cleared, new row visible.
        let added = relayer.configuredRow(url: customURL)
        XCTAssertTrue(added.waitForExistence(timeout: 5),
                      "custom URL should appear in Configured after Add")
    }
}
