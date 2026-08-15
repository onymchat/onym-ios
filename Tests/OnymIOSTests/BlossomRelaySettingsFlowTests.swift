import XCTest
@testable import OnymIOS
import OnymDiscovery
import OnymFoundation
import OnymTransportBlossom
import OnymSettings

@MainActor
final class BlossomRelaySettingsFlowTests: XCTestCase {

    func test_validate_acceptsHttpsAndHttp() {
        XCTAssertNotNil(BlossomRelaySettingsFlow.validate("https://blossom.example.com"))
        XCTAssertNotNil(BlossomRelaySettingsFlow.validate("http://localhost:3000"))
    }

    func test_validate_rejectsWssAndBareString() {
        XCTAssertNil(BlossomRelaySettingsFlow.validate("wss://blossom.example.com"),
                     "wss not accepted — Blossom is HTTP(S)")
        XCTAssertNil(BlossomRelaySettingsFlow.validate("blossom.example.com"),
                     "no scheme not accepted")
        XCTAssertNil(BlossomRelaySettingsFlow.validate(""))
        XCTAssertNil(BlossomRelaySettingsFlow.validate("https://"),
                     "missing host not accepted")
    }

    func test_tappedAddCustom_invalidURL_setsErrorAndKeepsDraft() async throws {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let flow = BlossomRelaySettingsFlow(repository: repo)
        flow.customDraftChanged("wss://wrong-scheme")
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertEqual(flow.state.customDraft, "wss://wrong-scheme",
                       "draft must be kept so the user can edit")
    }

    func test_tappedAddCustom_validURL_clearsDraftAndAdds() async throws {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let flow = BlossomRelaySettingsFlow(repository: repo)
        flow.customDraftChanged("https://blossom.example.com")
        flow.tappedAddCustom()
        XCTAssertEqual(flow.state.customDraft, "")
        XCTAssertNil(flow.state.customDraftError)
        try await Task.sleep(nanoseconds: 50_000_000)
        let endpoints = await repo.currentEndpoints()
        XCTAssertTrue(endpoints.contains { $0.url.absoluteString == "https://blossom.example.com" })
    }

    func test_start_drainsRepositorySnapshotsIntoState() async throws {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let flow = BlossomRelaySettingsFlow(repository: repo)
        flow.start()
        try await waitFor { flow.state.snapshot.endpoints.count == 1 }
    }

    // MARK: - make active

    func test_tappedMakeActive_promotesEndpointToHead() async throws {
        let a = BlossomServerEndpoint.custom(url: URL(string: "https://a.example")!)
        let b = BlossomServerEndpoint.custom(url: URL(string: "https://b.example")!)
        let store = InMemoryBlossomServersSelectionStore(
            initial: BlossomServersConfiguration(endpoints: [a, b], hasUserInteracted: true)
        )
        let repo = BlossomServersRepository(store: store)
        let flow = BlossomRelaySettingsFlow(repository: repo)

        flow.tappedMakeActive(url: b.url)

        try await waitFor { store.load().endpoints.first?.url == b.url }
        XCTAssertEqual(store.load().endpoints.map(\.url), [b.url, a.url])
    }

    // MARK: - catalog surface

    func test_start_installsCatalogEntriesFromStream() async throws {
        let repo = BlossomServersRepository(
            store: InMemoryBlossomServersSelectionStore(initial: .empty)
        )
        let entry = try Self.catalogEntry(componentId: "onym:component:blobs-one")
        let flow = BlossomRelaySettingsFlow(
            repository: repo,
            discovery: Self.picker(entries: { [entry] })
        )

        XCTAssertTrue(flow.catalogEntries.isEmpty, "empty before start")
        flow.start()

        try await waitFor { flow.catalogEntries.count == 1 }
        XCTAssertEqual(flow.catalogEntries.first?.entry.componentId, "onym:component:blobs-one")
        XCTAssertNil(flow.activeConsent(for: entry), "no pinned consent in this fixture")
        XCTAssertNil(flow.consentedOffer(for: entry))
    }

    func test_refreshCatalog_reReadsAggregateOnce() async throws {
        let repo = BlossomServersRepository(
            store: InMemoryBlossomServersSelectionStore(initial: .empty)
        )
        let first = try Self.catalogEntry(componentId: "onym:component:blobs-one")
        let second = try Self.catalogEntry(componentId: "onym:component:blobs-two")
        // Mutable backing list: the one-shot stream serves the initial
        // aggregate; refreshCatalog must re-read and see the growth.
        let served = ServedEntries(entries: [first])
        let flow = BlossomRelaySettingsFlow(
            repository: repo,
            discovery: Self.picker(entries: { served.entries })
        )
        flow.start()
        try await waitFor { flow.catalogEntries.count == 1 }

        served.entries = [first, second]
        flow.refreshCatalog()

        try await waitFor { flow.catalogEntries.count == 2 }
        XCTAssertEqual(
            flow.catalogEntries.map(\.entry.componentId),
            ["onym:component:blobs-one", "onym:component:blobs-two"]
        )
    }

    func test_noDiscovery_catalogStaysEmptyAfterStartAndRefresh() async throws {
        let repo = BlossomServersRepository(
            store: InMemoryBlossomServersSelectionStore(initial: .empty)
        )
        let flow = BlossomRelaySettingsFlow(repository: repo)
        flow.start()
        flow.refreshCatalog()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(flow.catalogEntries.isEmpty)
    }

    // MARK: - catalog fixtures

    /// Mutable entries the picker closures read — @MainActor-confined,
    /// the flow only calls the closures on the main actor.
    @MainActor
    private final class ServedEntries {
        var entries: [AttributedCatalogEntry]
        init(entries: [AttributedCatalogEntry]) { self.entries = entries }
    }

    private static func picker(
        entries: @escaping @MainActor () -> [AttributedCatalogEntry]
    ) -> DiscoveryModulePicker {
        DiscoveryModulePicker(
            entries: { await entries() },
            activeConsent: { _ in nil },
            makeConsentFlow: { _ in fatalError("consent flow not exercised by these tests") }
        )
    }

    private static func catalogEntry(componentId: String) throws -> AttributedCatalogEntry {
        let json: [String: Any] = [
            "componentId": componentId,
            "seatType": "blob.storage",
            "manifest": [
                "uri": "https://provider.example/manifests/"
                    + componentId.replacingOccurrences(of: ":", with: "-") + ".json",
                "digest": "sha256:" + String(repeating: "0", count: 64),
            ],
            "operator": "onym:key:" + String(repeating: "ab", count: 32),
            "profiles": [],
            "evidence": [],
            "listedAt": "2026-01-01T00:00:00Z",
            "relationship": "none",
            "placement": "neutral",
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(
            CatalogEntry.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        return AttributedCatalogEntry(
            entry: entry,
            source: SourceAttribution(
                providerId: "onym:component:test-provider",
                sourceLabel: "Test Provider",
                catalogId: "public",
                snapshotDigest: "sha256:" + String(repeating: "0", count: 64),
                relationship: "none",
                placement: "neutral"
            )
        )
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out", file: file, line: line)
    }
}
