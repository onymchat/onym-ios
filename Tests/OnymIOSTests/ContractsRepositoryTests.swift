import XCTest
@testable import OnymIOS

/// Repository against the in-memory fakes — focused on the binding
/// resolution rules (the part chains will read forever) plus the
/// reactive surface, selection persistence, and silent-on-error
/// background start.
final class ContractsRepositoryTests: XCTestCase {

    // MARK: - Fixtures

    private static let v002 = ContractRelease(
        release: "v0.0.2",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_002),  // newer
        contracts: [
            ContractEntry(network: .testnet, type: .anarchy,   id: "CDWYYK..."),
            ContractEntry(network: .testnet, type: .democracy, id: "CBEBQM..."),
        ]
    )
    private static let v001 = ContractRelease(
        release: "v0.0.1",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_001),  // older
        contracts: [
            ContractEntry(network: .testnet, type: .anarchy,   id: "CDSIJT..."),
            ContractEntry(network: .testnet, type: .democracy, id: "CBYHYJ..."),
        ]
    )
    /// Manifest with two testnet anarchy releases (v0.0.2 newest).
    private static let twoReleaseManifest = ContractsManifest(version: 1, releases: [v002, v001])

    private let testnetAnarchy = AnchorSelectionKey(network: .testnet, type: .anarchy)
    private let testnetTyranny = AnchorSelectionKey(network: .testnet, type: .tyranny)  // never published
    private let mainnetAnarchy = AnchorSelectionKey(network: .public, type: .anarchy)   // never published

    // MARK: - construction

    func test_init_loadsCachedManifestAndSelectionsFromStore() async {
        let store = InMemoryAnchorSelectionStore(
            selections: [testnetAnarchy: "v0.0.1"],
            manifest: Self.twoReleaseManifest
        )
        let fetcher = FakeContractsManifestFetcher(mode: .succeeds(.empty))
        let repo = ContractsRepository(fetcher: fetcher, store: store)

        let state = await repo.currentState()
        XCTAssertEqual(state.manifest, Self.twoReleaseManifest)
        XCTAssertEqual(state.selections[testnetAnarchy], "v0.0.1")
    }

    // MARK: - binding resolution rules (load-bearing)

    func test_binding_explicitSelection_wins() async {
        let store = InMemoryAnchorSelectionStore(
            selections: [testnetAnarchy: "v0.0.1"],
            manifest: Self.twoReleaseManifest
        )
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        let binding = await repo.binding(for: testnetAnarchy)
        XCTAssertEqual(binding?.release, "v0.0.1")
        XCTAssertEqual(binding?.contractID, "CDSIJT...")
    }

    func test_binding_noExplicit_defaultsToLatestRelease() async {
        let store = InMemoryAnchorSelectionStore(
            selections: [:],
            manifest: Self.twoReleaseManifest
        )
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        let binding = await repo.binding(for: testnetAnarchy)
        XCTAssertEqual(binding?.release, "v0.0.2", "default-to-latest must pick the newest publishedAt")
        XCTAssertEqual(binding?.contractID, "CDWYYK...")
    }

    func test_binding_noContractForKey_returnsNil() async {
        let store = InMemoryAnchorSelectionStore(manifest: Self.twoReleaseManifest)
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        let tyranny = await repo.binding(for: testnetTyranny)
        let mainnet = await repo.binding(for: mainnetAnarchy)
        XCTAssertNil(tyranny, "no published contract for tyranny on testnet → nil")
        XCTAssertNil(mainnet, "no published contract on mainnet at all → nil")
    }

    func test_binding_explicitSelectionForReleaseWithoutContractForKey_fallsBackToLatest() async {
        // User picked v0.0.2 for tyranny but neither release has a
        // tyranny contract — fall back to latest release that DOES
        // have one. Here that's still nil since neither does.
        let store = InMemoryAnchorSelectionStore(
            selections: [testnetTyranny: "v0.0.2"],
            manifest: Self.twoReleaseManifest
        )
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        let result = await repo.binding(for: testnetTyranny)
        XCTAssertNil(result)
    }

    // MARK: - mutators

    func test_select_persistsAndPushesSnapshot() async {
        let store = InMemoryAnchorSelectionStore(manifest: Self.twoReleaseManifest)
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        await repo.select(key: testnetAnarchy, releaseTag: "v0.0.1")
        XCTAssertEqual(store.loadSelections()[testnetAnarchy], "v0.0.1")
        let state = await repo.currentState()
        XCTAssertEqual(state.selections[testnetAnarchy], "v0.0.1")
    }

    func test_clearSelection_removesAndFallsBackToLatest() async {
        let store = InMemoryAnchorSelectionStore(
            selections: [testnetAnarchy: "v0.0.1"],
            manifest: Self.twoReleaseManifest
        )
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        await repo.clearSelection(key: testnetAnarchy)
        XCTAssertNil(store.loadSelections()[testnetAnarchy])
        let binding = await repo.binding(for: testnetAnarchy)
        XCTAssertEqual(binding?.release, "v0.0.2", "after clear → default-to-latest")
    }

    // MARK: - refresh + start

    func test_refresh_persistsAndPushesNewManifest() async throws {
        let store = InMemoryAnchorSelectionStore()
        let fetcher = FakeContractsManifestFetcher(mode: .succeeds(Self.twoReleaseManifest))
        let repo = ContractsRepository(fetcher: fetcher, store: store)

        try await repo.refresh()
        XCTAssertEqual(store.loadCachedManifest(), Self.twoReleaseManifest)
        let state = await repo.currentState()
        XCTAssertEqual(state.manifest, Self.twoReleaseManifest)
    }

    func test_refresh_throwsAndLeavesCachedManifestIntact() async {
        let cached = Self.twoReleaseManifest
        let store = InMemoryAnchorSelectionStore(manifest: cached)
        let fetcher = FakeContractsManifestFetcher(mode: .failing(URLError(.notConnectedToInternet)))
        let repo = ContractsRepository(fetcher: fetcher, store: store)

        do { try await repo.refresh(); XCTFail("expected throw") } catch { /* expected */ }

        let state = await repo.currentState()
        XCTAssertEqual(state.manifest, cached, "fetch failure must not erase cached manifest")
    }

    func test_start_isIdempotent_doesNotDoubleFetch() async throws {
        let store = InMemoryAnchorSelectionStore()
        let fetcher = FakeContractsManifestFetcher(mode: .succeeds(Self.twoReleaseManifest))
        let repo = ContractsRepository(fetcher: fetcher, store: store)

        await repo.start()
        await repo.start()
        await repo.start()

        // Wait for the first fetch to land.
        try await waitForManifest(repo: repo, timeoutMs: 1000)
        XCTAssertEqual(fetcher.fetchCallCount, 1, "start() must be idempotent")
    }

    func test_start_swallowsFetchFailures() async {
        let store = InMemoryAnchorSelectionStore()
        let fetcher = FakeContractsManifestFetcher(mode: .failing(URLError(.timedOut)))
        let repo = ContractsRepository(fetcher: fetcher, store: store)

        await repo.start()  // must not throw or trap
        try? await Task.sleep(for: .milliseconds(50))
        let state = await repo.currentState()
        XCTAssertTrue(state.manifest.releases.isEmpty)
    }

    // MARK: - snapshots

    func test_snapshots_emitsCurrentValueOnSubscribe() async throws {
        let store = InMemoryAnchorSelectionStore(manifest: Self.twoReleaseManifest)
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        var iterator = repo.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.manifest, Self.twoReleaseManifest)
    }

    func test_snapshots_emitsAfterSelect() async throws {
        let store = InMemoryAnchorSelectionStore(manifest: Self.twoReleaseManifest)
        let repo = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(.empty)),
            store: store
        )
        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial

        await repo.select(key: testnetAnarchy, releaseTag: "v0.0.1")
        let next = await iterator.next()
        XCTAssertEqual(next?.selections[testnetAnarchy], "v0.0.1")
    }

    // MARK: - helpers

    private func waitForManifest(
        repo: ContractsRepository,
        timeoutMs: Int
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while await repo.currentState().manifest.releases.isEmpty {
            if Date() > deadline {
                XCTFail("timed out waiting for non-empty manifest")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
