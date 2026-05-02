import XCTest
@testable import OnymIOS

/// Round-trip the persistence seam against real UserDefaults. Each
/// test gets its own suite so runs don't collide with each other or
/// the production `.standard` defaults — same isolation pattern as
/// the per-test Keychain service in `IdentityRepositoryTests`.
final class RelayerSelectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: UserDefaultsRelayerSelectionStore!

    override func setUp() {
        super.setUp()
        suiteName = "chat.onym.ios.relayer.tests.\(UUID().uuidString)"
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

    // MARK: - selection

    func test_loadSelection_returnsNilWhenNothingPersisted() {
        XCTAssertNil(store.loadSelection())
    }

    func test_saveSelection_thenLoadSelection_roundtripsKnown() {
        let endpoint = RelayerEndpoint(
            name: "Test",
            url: URL(string: "https://relayer.example.com")!,
            network: "testnet"
        )
        store.saveSelection(.known(endpoint))
        XCTAssertEqual(store.loadSelection(), .known(endpoint))
    }

    func test_saveSelection_thenLoadSelection_roundtripsCustom() {
        let url = URL(string: "https://my-private-relayer.dev")!
        store.saveSelection(.custom(url))
        XCTAssertEqual(store.loadSelection(), .custom(url))
    }

    func test_saveSelectionNil_clearsPersistedSelection() {
        store.saveSelection(.custom(URL(string: "https://x.com")!))
        store.saveSelection(nil)
        XCTAssertNil(store.loadSelection())
    }

    // MARK: - cached known list

    func test_loadCachedKnownList_returnsEmptyWhenNothingPersisted() {
        XCTAssertEqual(store.loadCachedKnownList(), [])
    }

    func test_saveCachedKnownList_thenLoad_roundtripsList() {
        let list = [
            RelayerEndpoint(name: "A", url: URL(string: "https://a.com")!, network: "testnet"),
            RelayerEndpoint(name: "B", url: URL(string: "https://b.com")!, network: "public"),
        ]
        store.saveCachedKnownList(list)
        XCTAssertEqual(store.loadCachedKnownList(), list)
    }

    func test_saveCachedKnownList_overwrites() {
        store.saveCachedKnownList([
            RelayerEndpoint(name: "A", url: URL(string: "https://a.com")!, network: "testnet")
        ])
        store.saveCachedKnownList([
            RelayerEndpoint(name: "B", url: URL(string: "https://b.com")!, network: "public")
        ])
        XCTAssertEqual(store.loadCachedKnownList().map(\.name), ["B"])
    }
}
