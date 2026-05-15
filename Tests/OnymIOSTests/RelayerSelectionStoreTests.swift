import XCTest
@testable import OnymIOS

/// UserDefaults round-trip with per-test suite isolation. Same pattern
/// as `AnchorSelectionStoreTests` and the per-test Keychain service in
/// `IdentityRepositoryTests`.
///
/// Also exercises the one-time migration from PR #18's
/// single-selection format — the legacy `app.onym.ios.relayer.selection`
/// blob (`RelayerSelection` enum with `.known`/`.custom` cases) projects
/// onto a one-endpoint `RelayerConfiguration` with that endpoint as
/// primary, strategy `.primary`. After successful migration the legacy
/// key is removed.
final class RelayerSelectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: UserDefaultsRelayerSelectionStore!

    override func setUp() {
        super.setUp()
        suiteName = "app.onym.ios.relayer.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsRelayerSelectionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    // MARK: - configuration round-trip

    func test_loadConfiguration_returnsEmptyWhenNothingPersisted() {
        XCTAssertEqual(store.loadConfiguration(), .empty)
    }

    func test_saveAndLoadConfiguration_roundtripsAllFields() {
        let endpoint = RelayerEndpoint(
            name: "Test",
            url: URL(string: "https://relayer-test.example")!,
            networks: ["testnet"]
        )
        let config = RelayerConfiguration(
            endpoints: [endpoint],
            primaryURL: endpoint.url,
            strategy: .primary
        )
        store.saveConfiguration(config)
        XCTAssertEqual(store.loadConfiguration(), config)
    }

    func test_saveConfiguration_overwrites() {
        let a = RelayerEndpoint(name: "A", url: URL(string: "https://a.example")!, networks: ["testnet"])
        let b = RelayerEndpoint(name: "B", url: URL(string: "https://b.example")!, networks: ["public"])
        store.saveConfiguration(RelayerConfiguration(endpoints: [a], primaryURL: a.url, strategy: .primary))
        store.saveConfiguration(RelayerConfiguration(endpoints: [a, b], primaryURL: b.url, strategy: .random))

        let loaded = store.loadConfiguration()
        XCTAssertEqual(loaded.endpoints, [a, b])
        XCTAssertEqual(loaded.primaryURL, b.url)
        XCTAssertEqual(loaded.strategy, .random)
    }

    // MARK: - cached known list

    func test_loadCachedKnownList_returnsEmptyWhenNothingPersisted() {
        XCTAssertEqual(store.loadCachedKnownList(), [])
    }

    func test_saveCachedKnownList_thenLoad_roundtripsList() {
        let list = [
            RelayerEndpoint(name: "A", url: URL(string: "https://a.com")!, networks: ["testnet"]),
            RelayerEndpoint(name: "B", url: URL(string: "https://b.com")!, networks: ["public"]),
        ]
        store.saveCachedKnownList(list)
        XCTAssertEqual(store.loadCachedKnownList(), list)
    }

    // MARK: - PR #18 migration

    func test_migration_legacyKnownSelection_yieldsSingleEndpointConfig() throws {
        // Plant a legacy `.known(endpoint)` blob in the suite, then
        // load and assert it migrates to a one-endpoint config.
        let endpoint = RelayerEndpoint(
            name: "Legacy",
            url: URL(string: "https://legacy.example")!,
            networks: ["testnet"]
        )
        let legacyJSON = #"{ "known": { "name": "Legacy", "url": "https://legacy.example", "network": "testnet" } }"#
        defaults.set(Data(legacyJSON.utf8), forKey: "app.onym.ios.relayer.selection")

        let migrated = store.loadConfiguration()
        XCTAssertEqual(migrated.endpoints, [endpoint])
        XCTAssertEqual(migrated.primaryURL, endpoint.url)
        XCTAssertEqual(migrated.strategy, .primary)
    }

    func test_migration_legacyCustomSelection_yieldsSingleEndpointConfig() throws {
        // Legacy `.custom(url)` synthesises a custom-network endpoint.
        let legacyJSON = #"{ "custom": { "_0": "https://custom.example" } }"#
        defaults.set(Data(legacyJSON.utf8), forKey: "app.onym.ios.relayer.selection")

        let migrated = store.loadConfiguration()
        XCTAssertEqual(migrated.endpoints.count, 1)
        XCTAssertEqual(migrated.endpoints.first?.url, URL(string: "https://custom.example"))
        XCTAssertEqual(migrated.endpoints.first?.networks, [RelayerEndpoint.customNetwork])
        XCTAssertEqual(migrated.primaryURL, URL(string: "https://custom.example"))
        XCTAssertEqual(migrated.strategy, .primary)
    }

    func test_migration_runsOnlyOnce_legacyKeyRemovedAfterMigration() throws {
        let legacyJSON = #"{ "known": { "name": "Legacy", "url": "https://legacy.example", "network": "testnet" } }"#
        defaults.set(Data(legacyJSON.utf8), forKey: "app.onym.ios.relayer.selection")

        // First load triggers migration.
        _ = store.loadConfiguration()

        // Legacy key must be gone, replaced by the new configuration key.
        XCTAssertNil(defaults.data(forKey: "app.onym.ios.relayer.selection"))
        XCTAssertNotNil(defaults.data(forKey: "app.onym.ios.relayer.configuration"))

        // Second load returns the migrated value without retriggering migration.
        let second = store.loadConfiguration()
        XCTAssertEqual(second.endpoints.count, 1)
    }

    func test_migration_unreadableLegacyBlob_dropsItAndReturnsEmpty() throws {
        defaults.set(Data("garbage".utf8), forKey: "app.onym.ios.relayer.selection")
        let migrated = store.loadConfiguration()
        XCTAssertEqual(migrated, .empty)
        XCTAssertNil(defaults.data(forKey: "app.onym.ios.relayer.selection"),
                     "unreadable legacy blob must be dropped, not left lingering")
    }

    func test_noLegacy_noConfiguration_returnsEmptyWithoutWriting() {
        // Cold start, no legacy blob, no new config — load returns
        // empty and DOESN'T persist anything (avoids gratuitous
        // UserDefaults writes on every cold launch).
        let result = store.loadConfiguration()
        XCTAssertEqual(result, .empty)
        XCTAssertNil(defaults.data(forKey: "app.onym.ios.relayer.configuration"))
    }
}
