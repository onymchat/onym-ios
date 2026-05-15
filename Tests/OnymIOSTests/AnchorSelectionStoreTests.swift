import XCTest
@testable import OnymIOS

/// UserDefaults round-trip with per-test suite isolation. Mirrors
/// `RelayerSelectionStoreTests` from PR #18.
final class AnchorSelectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: UserDefaultsAnchorSelectionStore!

    override func setUp() {
        super.setUp()
        suiteName = "app.onym.ios.anchors.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsAnchorSelectionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    // MARK: - selections

    func test_loadSelections_returnsEmptyWhenNothingPersisted() {
        XCTAssertTrue(store.loadSelections().isEmpty)
    }

    func test_saveSelections_thenLoadSelections_roundtripsMap() {
        let key1 = AnchorSelectionKey(network: .testnet, type: .anarchy)
        let key2 = AnchorSelectionKey(network: .public, type: .oneonone)
        let original: [AnchorSelectionKey: String] = [key1: "v0.0.2", key2: "v1.0.0"]
        store.saveSelections(original)
        XCTAssertEqual(store.loadSelections(), original)
    }

    func test_saveSelections_overwrites() {
        let key = AnchorSelectionKey(network: .testnet, type: .anarchy)
        store.saveSelections([key: "v0.0.1"])
        store.saveSelections([key: "v0.0.2"])
        XCTAssertEqual(store.loadSelections(), [key: "v0.0.2"])
    }

    func test_saveSelectionsEmpty_clearsPersistedSelections() {
        store.saveSelections([
            AnchorSelectionKey(network: .testnet, type: .anarchy): "v0.0.1"
        ])
        store.saveSelections([:])
        XCTAssertTrue(store.loadSelections().isEmpty)
    }

    // MARK: - cached manifest

    func test_loadCachedManifest_returnsNilWhenNothingPersisted() {
        XCTAssertNil(store.loadCachedManifest())
    }

    func test_saveCachedManifest_thenLoad_roundtripsManifest() {
        let manifest = ContractsManifest(version: 1, releases: [
            ContractRelease(
                release: "v0.0.2",
                publishedAt: Date(timeIntervalSince1970: 1_730_000_000),
                contracts: [
                    ContractEntry(network: .testnet, type: .anarchy, id: "CDWYYK...RO2UMV"),
                ]
            )
        ])
        store.saveCachedManifest(manifest)
        XCTAssertEqual(store.loadCachedManifest(), manifest)
    }
}
