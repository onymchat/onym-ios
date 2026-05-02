import XCTest
@testable import OnymIOS

/// Repository against the in-memory fakes — fast, focused on:
/// - construction loads cached state from the store,
/// - list-shaped mutators (add / remove / setPrimary / setStrategy)
///   persist via the store and push a fresh snapshot,
/// - addEndpoint dedupes on URL (idempotent + updates metadata),
/// - removeEndpoint clears the primary marker if it pointed at the
///   removed endpoint,
/// - setPrimary is a no-op when the URL isn't in the configured list,
/// - selectURL respects the strategy stored in the configuration,
/// - background `start()` is idempotent (no double fetch) and silent
///   on error.
final class RelayerRepositoryTests: XCTestCase {
    private let a = RelayerEndpoint(name: "A", url: URL(string: "https://a.example")!, network: "testnet")
    private let b = RelayerEndpoint(name: "B", url: URL(string: "https://b.example")!, network: "testnet")
    private let c = RelayerEndpoint(name: "C", url: URL(string: "https://c.example")!, network: "public")

    // MARK: - construction

    func test_init_loadsCachedConfigurationAndKnownListFromStore() async {
        let config = RelayerConfiguration(endpoints: [a, b], primaryURL: a.url, strategy: .random)
        let store = InMemoryRelayerSelectionStore(configuration: config, cachedList: [a, b])
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        let state = await repo.currentState()
        XCTAssertEqual(state.configuration, config)
        XCTAssertEqual(state.knownList, [a, b])
    }

    // MARK: - addEndpoint

    func test_addEndpoint_persistsAndPushesSnapshot() async {
        let store = InMemoryRelayerSelectionStore()
        let repo = makeRepo(store: store)

        let inserted = await repo.addEndpoint(a)
        XCTAssertTrue(inserted)
        XCTAssertEqual(store.loadConfiguration().endpoints, [a])
        let endpoints = await repo.currentState().configuration.endpoints
        XCTAssertEqual(endpoints, [a])
    }

    func test_addEndpoint_dedupesOnURL_returnsFalseAndUpdatesMetadata() async {
        let store = InMemoryRelayerSelectionStore()
        let repo = makeRepo(store: store)

        await repo.addEndpoint(a)
        let renamed = RelayerEndpoint(name: "A renamed", url: a.url, network: a.network)
        let inserted = await repo.addEndpoint(renamed)

        XCTAssertFalse(inserted)
        let endpoints = await repo.currentState().configuration.endpoints
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?.name, "A renamed")
    }

    // MARK: - removeEndpoint

    func test_removeEndpoint_clearsPrimaryWhenItWasTheRemovedURL() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a, b], primaryURL: a.url, strategy: .primary)
        )
        let repo = makeRepo(store: store)

        await repo.removeEndpoint(url: a.url)
        let state = await repo.currentState()
        XCTAssertEqual(state.configuration.endpoints, [b])
        XCTAssertNil(state.configuration.primaryURL,
                     "primary marker must clear when its endpoint is removed")
    }

    func test_removeEndpoint_keepsPrimaryWhenADifferentURLIsRemoved() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a, b], primaryURL: a.url, strategy: .primary)
        )
        let repo = makeRepo(store: store)

        await repo.removeEndpoint(url: b.url)
        let state = await repo.currentState()
        XCTAssertEqual(state.configuration.endpoints, [a])
        XCTAssertEqual(state.configuration.primaryURL, a.url)
    }

    // MARK: - setPrimary

    func test_setPrimary_marksEndpointAndPushes() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a, b], primaryURL: nil, strategy: .primary)
        )
        let repo = makeRepo(store: store)

        await repo.setPrimary(url: b.url)
        let primary = await repo.currentState().configuration.primaryURL
        XCTAssertEqual(primary, b.url)
    }

    func test_setPrimary_noOpWhenURLNotInList() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a], primaryURL: a.url, strategy: .primary)
        )
        let repo = makeRepo(store: store)

        let stranger = URL(string: "https://stranger.example")!
        await repo.setPrimary(url: stranger)
        let primary = await repo.currentState().configuration.primaryURL
        XCTAssertEqual(primary, a.url,
                       "setting primary to a URL not in the list must be a no-op")
    }

    func test_setPrimary_nilClearsMarker() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a], primaryURL: a.url, strategy: .primary)
        )
        let repo = makeRepo(store: store)

        await repo.setPrimary(url: nil)
        let primary = await repo.currentState().configuration.primaryURL
        XCTAssertNil(primary)
    }

    // MARK: - setStrategy

    func test_setStrategy_persistsAndPushes() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a], primaryURL: a.url, strategy: .primary)
        )
        let repo = makeRepo(store: store)

        await repo.setStrategy(.random)
        let strategy = await repo.currentState().configuration.strategy
        XCTAssertEqual(strategy, .random)
    }

    // MARK: - selectURL

    func test_selectURL_emptyEndpoints_returnsNil() async {
        let repo = makeRepo()
        let url = await repo.selectURL()
        XCTAssertNil(url)
    }

    func test_selectURL_primaryStrategy_returnsPrimary() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a, b], primaryURL: b.url, strategy: .primary)
        )
        let repo = makeRepo(store: store)
        let url = await repo.selectURL()
        XCTAssertEqual(url, b.url)
    }

    func test_selectURL_randomStrategy_picksFromList() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a, b, c], primaryURL: nil, strategy: .random)
        )
        let repo = makeRepo(store: store)

        let allowed = Set([a.url, b.url, c.url])
        for _ in 0..<20 {
            let url = await repo.selectURL()
            XCTAssertTrue(allowed.contains(url ?? URL(string: "x:")!),
                          "selectURL under .random must return one of the configured URLs")
        }
    }

    // MARK: - snapshots

    func test_snapshots_emitsCurrentValueOnSubscribe() async {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [a], primaryURL: a.url, strategy: .primary),
            cachedList: [a]
        )
        let repo = makeRepo(store: store)

        var iterator = repo.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.configuration.endpoints, [a])
        XCTAssertEqual(first?.knownList, [a])
    }

    func test_snapshots_emitsAfterMutation() async {
        let repo = makeRepo()

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial empty
        await repo.addEndpoint(a)
        let next = await iterator.next()
        XCTAssertEqual(next?.configuration.endpoints, [a])
    }

    // MARK: - start

    func test_start_persistsAndPushesNewKnownList() async throws {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([a]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        await repo.start()
        try await waitForNonEmptyKnownList(repo: repo, timeoutMs: 1000)
        XCTAssertEqual(store.loadCachedKnownList(), [a])
    }

    func test_start_isIdempotent() async throws {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([a]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        await repo.start()
        await repo.start()
        await repo.start()
        try await waitForNonEmptyKnownList(repo: repo, timeoutMs: 1000)
        XCTAssertEqual(fetcher.fetchCallCount, 1)
    }

    func test_start_swallowsFetchFailures() async {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .failing(URLError(.timedOut)))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        await repo.start()
        try? await Task.sleep(for: .milliseconds(50))
        let knownList = await repo.currentState().knownList
        XCTAssertEqual(knownList, [])
    }

    // MARK: - helpers

    private func makeRepo(
        store: InMemoryRelayerSelectionStore = InMemoryRelayerSelectionStore(),
        fetcher: FakeKnownRelayersFetcher? = nil
    ) -> RelayerRepository {
        let f = fetcher ?? FakeKnownRelayersFetcher(mode: .succeeds([]))
        return RelayerRepository(fetcher: f, store: store)
    }

    private func waitForNonEmptyKnownList(
        repo: RelayerRepository,
        timeoutMs: Int
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while await repo.currentState().knownList.isEmpty {
            if Date() > deadline {
                XCTFail("timed out waiting for non-empty knownList")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
