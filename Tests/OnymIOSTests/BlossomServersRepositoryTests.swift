import XCTest
@testable import OnymIOS
import OnymTransportBlossom

/// Behavioral tests for `BlossomServersRepository` covering the
/// first-launch seed, mutation idempotency, and reset-to-default.
/// Mirrors `NostrRelaysRepositoryTests`.
final class BlossomServersRepositoryTests: XCTestCase {

    // MARK: - First-launch seed

    func test_init_emptyStore_seedsWithOnymOfficial() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints.first?.url.absoluteString, "https://blossom.onym.app")
        XCTAssertTrue(endpoints.first?.isDefault ?? false,
                      "seeded entry must carry isDefault = true")
    }

    func test_init_userInteractedEmpty_doesNotReseed() async {
        let store = InMemoryBlossomServersSelectionStore(
            initial: BlossomServersConfiguration(endpoints: [], hasUserInteracted: true)
        )
        let repo = BlossomServersRepository(store: store)
        let endpoints = await repo.currentEndpoints()
        XCTAssertTrue(endpoints.isEmpty,
                      "post-clear empty config must NOT re-seed")
    }

    func test_init_userInteractedNonEmpty_preservesUserList() async {
        let custom = BlossomServerEndpoint(
            name: "my server",
            url: URL(string: "https://blossom.example.com")!,
            isDefault: false
        )
        let store = InMemoryBlossomServersSelectionStore(
            initial: BlossomServersConfiguration(
                endpoints: [custom],
                hasUserInteracted: true
            )
        )
        let repo = BlossomServersRepository(store: store)
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints, [custom])
    }

    // MARK: - addEndpoint

    func test_addEndpoint_inserts_andFlipsUserInteracted() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let custom = BlossomServerEndpoint.custom(url: URL(string: "https://blossom.example.com")!)
        let inserted = await repo.addEndpoint(custom)
        XCTAssertTrue(inserted)
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.count, 2)
        XCTAssertTrue(store.load().hasUserInteracted)
    }

    func test_addEndpoint_dedupesOnURL() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let custom = BlossomServerEndpoint.custom(url: URL(string: "https://x.com")!)
        _ = await repo.addEndpoint(custom)
        let inserted = await repo.addEndpoint(custom)
        XCTAssertFalse(inserted, "duplicate URL must not insert again")
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.filter { $0.url == custom.url }.count, 1)
    }

    // MARK: - removeEndpoint

    func test_removeEndpoint_dropsTheRow_andFlipsUserInteracted() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let seedURL = URL(string: "https://blossom.onym.app")!
        await repo.removeEndpoint(url: seedURL)
        let endpoints = await repo.currentEndpoints()
        XCTAssertTrue(endpoints.isEmpty)
        XCTAssertTrue(store.load().hasUserInteracted)
    }

    // MARK: - resetToDefault

    func test_resetToDefault_reinstallsSeed_andClearsInteractionFlag() async {
        let store = InMemoryBlossomServersSelectionStore(
            initial: BlossomServersConfiguration(endpoints: [], hasUserInteracted: true)
        )
        let repo = BlossomServersRepository(store: store)
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
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let stream = repo.snapshots
        var iterator = stream.makeAsyncIterator()

        let s0 = await iterator.next()
        XCTAssertEqual(s0?.endpoints.count, 1)

        await repo.addEndpoint(BlossomServerEndpoint.custom(url: URL(string: "https://a.example")!))
        let s1 = await iterator.next()
        XCTAssertEqual(s1?.endpoints.count, 2)

        await repo.removeEndpoint(url: URL(string: "https://a.example")!)
        let s2 = await iterator.next()
        XCTAssertEqual(s2?.endpoints.count, 1)
    }

    // MARK: - GitHub-published default fetch

    private struct StubFetcher: KnownBlossomServersFetcher {
        let result: Result<[BlossomServerEndpoint], Error>
        func fetchLatest() async throws -> [BlossomServerEndpoint] { try result.get() }
    }

    private static let published = BlossomServerEndpoint(
        name: "Published", url: URL(string: "https://published.example")!, isDefault: true
    )

    func test_refresh_installsPublishedListWhenNotUserInteracted() async throws {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store, fetcher: StubFetcher(result: .success([Self.published])))
        try await repo.refresh()
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints, [Self.published])
        XCTAssertFalse(store.load().hasUserInteracted)
    }

    func test_refresh_doesNotOverwriteUserCustomisedList() async throws {
        let custom = BlossomServerEndpoint.custom(url: URL(string: "https://mine.example")!)
        let store = InMemoryBlossomServersSelectionStore(
            initial: BlossomServersConfiguration(endpoints: [custom], hasUserInteracted: true)
        )
        let repo = BlossomServersRepository(store: store, fetcher: StubFetcher(result: .success([Self.published])))
        try await repo.refresh()
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints, [custom])
    }

    func test_resetToDefault_fetchesPublishedList() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store, fetcher: StubFetcher(result: .success([Self.published])))
        await repo.resetToDefault()
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints, [Self.published])
    }

    // MARK: - makeActive / addEndpoint(makeActive:)

    func test_addEndpoint_makeActive_insertsNewEndpointAtHead() async {
        // First launch seeds Onym Official at index 0; a make-active
        // add (the catalog consent pick) must land FIRST — the
        // upload/download target — with the seed kept right behind.
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let picked = BlossomServerEndpoint(
            name: "Picked", url: URL(string: "https://picked.example")!, isDefault: false
        )

        let inserted = await repo.addEndpoint(picked, makeActive: true)

        XCTAssertTrue(inserted)
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.first, picked,
                       "make-active add must place the pick at the head")
        XCTAssertEqual(endpoints.count, 2)
        XCTAssertEqual(endpoints.last?.url.absoluteString, "https://blossom.onym.app",
                       "the seeded default stays in the list behind the pick")
        XCTAssertTrue(store.load().hasUserInteracted)
    }

    func test_addEndpoint_makeActive_movesExistingEndpointToHead() async {
        let a = BlossomServerEndpoint.custom(url: URL(string: "https://a.example")!)
        let b = BlossomServerEndpoint.custom(url: URL(string: "https://b.example")!)
        let store = InMemoryBlossomServersSelectionStore(
            initial: BlossomServersConfiguration(endpoints: [a, b], hasUserInteracted: true)
        )
        let repo = BlossomServersRepository(store: store)

        let renamed = BlossomServerEndpoint(name: "B renamed", url: b.url, isDefault: false)
        let inserted = await repo.addEndpoint(renamed, makeActive: true)

        XCTAssertFalse(inserted, "same URL is an update, not an insert")
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.map(\.url), [b.url, a.url],
                       "existing endpoint moves to the head, others keep order")
        XCTAssertEqual(endpoints.first?.name, "B renamed",
                       "metadata still updates on a make-active re-add")
    }

    func test_addEndpoint_withoutMakeActive_stillAppends() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let added = BlossomServerEndpoint.custom(url: URL(string: "https://added.example")!)

        await repo.addEndpoint(added)

        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.first?.url.absoluteString, "https://blossom.onym.app",
                       "plain add keeps the current active server")
        XCTAssertEqual(endpoints.last, added)
    }

    func test_makeActive_movesConfiguredEndpointToHead() async {
        let a = BlossomServerEndpoint.custom(url: URL(string: "https://a.example")!)
        let b = BlossomServerEndpoint.custom(url: URL(string: "https://b.example")!)
        let c = BlossomServerEndpoint.custom(url: URL(string: "https://c.example")!)
        let store = InMemoryBlossomServersSelectionStore(
            initial: BlossomServersConfiguration(endpoints: [a, b, c], hasUserInteracted: true)
        )
        let repo = BlossomServersRepository(store: store)

        await repo.makeActive(url: c.url)

        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints, [c, a, b],
                       "promoted endpoint heads the list; the rest keep relative order")
        XCTAssertEqual(store.load().endpoints, [c, a, b], "promotion is persisted")
    }

    func test_makeActive_unknownURL_isNoOp() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)  // seeds Onym Official

        await repo.makeActive(url: URL(string: "https://stranger.example")!)

        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.first?.url.absoluteString, "https://blossom.onym.app")
        XCTAssertFalse(store.load().hasUserInteracted,
                       "a no-op promotion must not count as user interaction")
    }

    func test_makeActive_alreadyFirst_doesNotFlipUserInteracted() async {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)  // seeds Onym Official at head

        await repo.makeActive(url: URL(string: "https://blossom.onym.app")!)

        XCTAssertFalse(store.load().hasUserInteracted,
                       "promoting the already-active server changes nothing")
    }

    func test_resetToDefault_offline_fallsBackToSeed() async {
        struct Boom: Error {}
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store, fetcher: StubFetcher(result: .failure(Boom())))
        await repo.resetToDefault()
        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.first?.url.absoluteString, "https://blossom.onym.app",
                       "offline reset must fall back to the hardcoded seed")
    }
}
