import XCTest
@testable import OnymIOS

/// Repository against the in-memory fakes — fast, focused on:
/// - the snapshot replay-on-subscribe contract
/// - selection persistence (delegates to store; this just verifies
///   the wire-up and the snapshot push)
/// - background `start()` populates the cached known list from the
///   fetcher and pushes a snapshot
/// - `start()` is idempotent — second call is a no-op while the
///   first is in flight (no double-fetch)
/// - `refresh()` surfaces errors to the caller (UI can show
///   progress / error states)
final class RelayerRepositoryTests: XCTestCase {
    private let testEndpoint = RelayerEndpoint(
        name: "Test",
        url: URL(string: "https://relayer-test.example")!,
        network: "testnet"
    )

    // MARK: - construction

    func test_init_loadsCachedSelectionAndKnownListFromStore() async {
        let store = InMemoryRelayerSelectionStore(
            selection: .known(testEndpoint),
            cachedList: [testEndpoint]
        )
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        let state = await repo.currentState()
        XCTAssertEqual(state.selection, .known(testEndpoint))
        XCTAssertEqual(state.knownList, [testEndpoint])
    }

    // MARK: - select / selectCustom / clearSelection

    func test_select_persistsAndPushesSnapshot() async {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        await repo.select(testEndpoint)

        XCTAssertEqual(store.loadSelection(), .known(testEndpoint))
        let state = await repo.currentState()
        XCTAssertEqual(state.selection, .known(testEndpoint))
    }

    func test_selectCustom_persistsAndPushesSnapshot() async {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)
        let customURL = URL(string: "https://my-relayer.dev")!

        await repo.selectCustom(url: customURL)

        XCTAssertEqual(store.loadSelection(), .custom(customURL))
        let state = await repo.currentState()
        XCTAssertEqual(state.selection, .custom(customURL))
    }

    func test_clearSelection_removesPersistedAndPushesNilSnapshot() async {
        let store = InMemoryRelayerSelectionStore(selection: .known(testEndpoint))
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        await repo.clearSelection()

        XCTAssertNil(store.loadSelection())
        let state = await repo.currentState()
        XCTAssertNil(state.selection)
    }

    // MARK: - refresh

    func test_refresh_persistsAndPushesNewKnownList() async throws {
        let store = InMemoryRelayerSelectionStore()
        let fetched = [testEndpoint]
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds(fetched))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        try await repo.refresh()

        XCTAssertEqual(store.loadCachedKnownList(), fetched)
        let state = await repo.currentState()
        XCTAssertEqual(state.knownList, fetched)
    }

    func test_refresh_throwsAndLeavesCachedListIntact() async {
        let cached = [testEndpoint]
        let store = InMemoryRelayerSelectionStore(cachedList: cached)
        let fetcher = FakeKnownRelayersFetcher(mode: .failing(URLError(.notConnectedToInternet)))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        do {
            try await repo.refresh()
            XCTFail("expected throw")
        } catch {
            // expected
        }

        let state = await repo.currentState()
        XCTAssertEqual(state.knownList, cached, "fetch failure must not erase the cached list")
    }

    // MARK: - start

    func test_start_kicksOffBackgroundRefresh() async throws {
        let store = InMemoryRelayerSelectionStore()
        let fetched = [testEndpoint]
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds(fetched))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        await repo.start()
        // start() returns immediately; await the first non-empty snapshot.
        let observed = try await waitForNonEmptyKnownList(repo: repo, timeoutMs: 1000)
        XCTAssertEqual(observed, fetched)
    }

    func test_start_swallowsFetchFailures() async {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .failing(URLError(.timedOut)))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        // Should not throw or trap — failures during background start
        // are silent so app launch never crashes on a transient
        // network problem.
        await repo.start()

        // Wait one scheduler tick so the start task can finish.
        try? await Task.sleep(for: .milliseconds(50))
        let state = await repo.currentState()
        XCTAssertEqual(state.knownList, [], "fetch failed; no cache; list stays empty")
    }

    func test_start_isIdempotent_doesNotDoubleFetch() async throws {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([testEndpoint]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        await repo.start()
        await repo.start()
        await repo.start()

        // Wait until at least the first fetch has completed.
        _ = try await waitForNonEmptyKnownList(repo: repo, timeoutMs: 1000)
        XCTAssertEqual(fetcher.fetchCallCount, 1, "start() must be idempotent")
    }

    // MARK: - snapshots

    func test_snapshots_emitsCurrentValueOnSubscribe() async throws {
        let store = InMemoryRelayerSelectionStore(
            selection: .known(testEndpoint),
            cachedList: [testEndpoint]
        )
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        var iterator = repo.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.selection, .known(testEndpoint))
        XCTAssertEqual(first?.knownList, [testEndpoint])
    }

    func test_snapshots_emitsAfterSelectMutation() async throws {
        let store = InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds([]))
        let repo = RelayerRepository(fetcher: fetcher, store: store)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial empty

        await repo.select(testEndpoint)

        let next = await iterator.next()
        XCTAssertEqual(next?.selection, .known(testEndpoint))
    }

    // MARK: - helpers

    private func waitForNonEmptyKnownList(
        repo: RelayerRepository,
        timeoutMs: Int
    ) async throws -> [RelayerEndpoint] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while true {
            let state = await repo.currentState()
            if !state.knownList.isEmpty { return state.knownList }
            if Date() > deadline {
                XCTFail("timed out waiting for non-empty knownList")
                return []
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
