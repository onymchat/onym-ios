import XCTest
@testable import OnymIOS

/// Behavioral tests for `NostrRelaysRepository` covering the
/// first-launch seed, mutation idempotency, and reset-to-default.
final class NostrRelaysRepositoryTests: XCTestCase {

    // MARK: - First-launch seed

    func test_init_emptyStore_seedsWithOnymOfficial() async {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?.url.absoluteString, "wss://nostr.onym.chat")
        XCTAssertTrue(endpoints.first?.isDefault ?? false,
                      "seeded entry must carry isDefault = true")
    }

    func test_init_userInteractedEmpty_doesNotReseed() async {
        // User explicitly cleared the list on a prior launch — the
        // sticky `hasUserInteracted` flag must keep the list empty.
        let store = InMemoryNostrRelaysSelectionStore(
            initial: NostrRelaysConfiguration(endpoints: [], hasUserInteracted: true)
        )
        let repo = NostrRelaysRepository(store: store)
        let endpoints = await repo.currentEndpoints()
        XCTAssertTrue(endpoints.isEmpty,
                      "post-clear empty config must NOT re-seed")
    }

    func test_init_userInteractedNonEmpty_preservesUserList() async {
        let custom = NostrRelayEndpoint(
            name: "my relay",
            url: URL(string: "wss://relay.example.com")!,
            isDefault: false
        )
        let store = InMemoryNostrRelaysSelectionStore(
            initial: NostrRelaysConfiguration(
                endpoints: [custom],
                hasUserInteracted: true
            )
        )
        let repo = NostrRelaysRepository(store: store)
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints, [custom])
    }

    // MARK: - addEndpoint

    func test_addEndpoint_inserts_andFlipsUserInteracted() async {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        // Init seeded → 1 entry.
        let custom = NostrRelayEndpoint.custom(url: URL(string: "wss://relay.example.com")!)
        let inserted = await repo.addEndpoint(custom)
        XCTAssertTrue(inserted)
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.count, 2)
        // Persisted with hasUserInteracted = true.
        XCTAssertTrue(store.load().hasUserInteracted)
    }

    func test_addEndpoint_dedupesOnURL() async {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        let custom = NostrRelayEndpoint.custom(url: URL(string: "wss://x.com")!)
        _ = await repo.addEndpoint(custom)
        let inserted = await repo.addEndpoint(custom)
        XCTAssertFalse(inserted, "duplicate URL must not insert again")
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.filter { $0.url == custom.url }.count, 1)
    }

    // MARK: - removeEndpoint

    func test_removeEndpoint_dropsTheRow_andFlipsUserInteracted() async {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        let seedURL = URL(string: "wss://nostr.onym.chat")!
        await repo.removeEndpoint(url: seedURL)
        let endpoints = await repo.currentEndpoints()
        XCTAssertTrue(endpoints.isEmpty)
        XCTAssertTrue(store.load().hasUserInteracted)
    }

    // MARK: - resetToDefault

    func test_resetToDefault_reinstallsSeed_andClearsInteractionFlag() async {
        let store = InMemoryNostrRelaysSelectionStore(
            initial: NostrRelaysConfiguration(endpoints: [], hasUserInteracted: true)
        )
        let repo = NostrRelaysRepository(store: store)
        // Pre-condition: empty + sticky.
        let preEndpoints = await repo.currentEndpoints()
        XCTAssertTrue(preEndpoints.isEmpty)

        await repo.resetToDefault()
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?.isDefault, true)
        XCTAssertFalse(store.load().hasUserInteracted,
                       "resetToDefault must clear hasUserInteracted so the seed sticks")
    }

    // MARK: - snapshots stream

    func test_snapshots_emitsOnEveryMutation() async throws {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        let stream = repo.snapshots
        var iterator = stream.makeAsyncIterator()

        // Initial snapshot (replay of seed).
        let s0 = await iterator.next()
        XCTAssertEqual(s0?.endpoints.count, 1)

        await repo.addEndpoint(NostrRelayEndpoint.custom(url: URL(string: "wss://a.example")!))
        let s1 = await iterator.next()
        XCTAssertEqual(s1?.endpoints.count, 2)

        await repo.removeEndpoint(url: URL(string: "wss://a.example")!)
        let s2 = await iterator.next()
        XCTAssertEqual(s2?.endpoints.count, 1)
    }
}
