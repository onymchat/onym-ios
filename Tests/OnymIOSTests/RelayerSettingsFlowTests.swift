import XCTest
@testable import OnymIOS

/// Settings flow against a real `RelayerRepository` backed by the
/// in-memory store + fake fetcher. Asserts intent dispatch
/// (add / remove / setPrimary / setStrategy / addCustom), the
/// local-only custom-URL draft + validation, and the
/// `unconfiguredKnownList` filter that hides published entries the
/// user has already added.
@MainActor
final class RelayerSettingsFlowTests: XCTestCase {
    private let testEndpoint = RelayerEndpoint(
        name: "Test",
        url: URL(string: "https://relayer-test.example")!,
        networks: ["testnet"]
    )

    private func makeFlow(
        store: InMemoryRelayerSelectionStore? = nil,
        fetcherMode: FakeKnownRelayersFetcher.Mode = .succeeds([])
    ) -> (RelayerSettingsFlow, RelayerRepository, InMemoryRelayerSelectionStore) {
        let resolvedStore = store ?? InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: fetcherMode)
        let repo = RelayerRepository(fetcher: fetcher, store: resolvedStore)
        let flow = RelayerSettingsFlow(repository: repo)
        return (flow, repo, resolvedStore)
    }

    // MARK: - tappedAddKnown

    func test_tappedAddKnown_addsViaRepository() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.tappedAddKnown(testEndpoint)
        try await waitFor { store.loadConfiguration().endpoints == [self.testEndpoint] }
    }

    // MARK: - custom URL draft

    func test_customDraftChanged_updatesStateAndClearsError() {
        let (flow, _, _) = makeFlow()
        flow.tappedAddCustom()  // empty draft → sets error
        XCTAssertNotNil(flow.state.customDraftError)

        flow.customDraftChanged("https://x.com")
        XCTAssertEqual(flow.state.customDraft, "https://x.com")
        XCTAssertNil(flow.state.customDraftError)
    }

    func test_tappedAddCustom_validURL_addsAsCustomEndpointAndClearsDraft() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.customDraftChanged("https://my-relayer.dev")
        flow.tappedAddCustom()

        try await waitFor { !store.loadConfiguration().endpoints.isEmpty }
        let endpoint = store.loadConfiguration().endpoints.first
        XCTAssertEqual(endpoint?.url, URL(string: "https://my-relayer.dev"))
        XCTAssertEqual(endpoint?.networks, [RelayerEndpoint.customNetwork])
        XCTAssertEqual(endpoint?.name, "my-relayer.dev",
                       "custom endpoint name defaults to the URL host")
        XCTAssertEqual(flow.state.customDraft, "",
                       "successful add must clear the draft so the field is ready for the next entry")
    }

    func test_tappedAddCustom_emptyDraft_setsErrorAndDoesNotAdd() {
        let (flow, _, store) = makeFlow()
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertTrue(store.loadConfiguration().endpoints.isEmpty)
    }

    func test_tappedAddCustom_garbageDraft_setsErrorAndDoesNotAdd() {
        let (flow, _, store) = makeFlow()
        flow.customDraftChanged("not-a-url at all")
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertTrue(store.loadConfiguration().endpoints.isEmpty)
    }

    func test_tappedAddCustom_ftpScheme_setsErrorAndDoesNotAdd() {
        let (flow, _, store) = makeFlow()
        flow.customDraftChanged("ftp://relayer.example.com")
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertTrue(store.loadConfiguration().endpoints.isEmpty)
    }

    func test_tappedAddCustom_trimsWhitespace() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.customDraftChanged("   https://relayer.example.com  \n")
        flow.tappedAddCustom()
        try await waitFor { !store.loadConfiguration().endpoints.isEmpty }
        XCTAssertEqual(
            store.loadConfiguration().endpoints.first?.url,
            URL(string: "https://relayer.example.com")
        )
    }

    // MARK: - tappedRemove / tappedSetPrimary / tappedStrategy

    func test_tappedRemove_removesViaRepository() async throws {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedRemove(url: testEndpoint.url)
        try await waitFor { store.loadConfiguration().endpoints.isEmpty }
    }

    func test_tappedSetPrimary_marksViaRepository() async throws {
        let other = RelayerEndpoint(name: "Other", url: URL(string: "https://other.example")!, networks: ["testnet"])
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint, other], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedSetPrimary(url: other.url)
        try await waitFor { store.loadConfiguration().primaryURL == other.url }
    }

    func test_tappedStrategy_setsViaRepository() async throws {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedStrategy(.random)
        try await waitFor { store.loadConfiguration().strategy == .random }
    }

    // MARK: - read helpers

    func test_unconfiguredKnownList_hidesAlreadyConfiguredURLs() async throws {
        let known = [
            testEndpoint,
            RelayerEndpoint(name: "Other", url: URL(string: "https://other.example")!, networks: ["public"])
        ]
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: nil, strategy: .primary),
            cachedList: known
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        try await waitFor { !flow.state.snapshot.knownList.isEmpty }
        let remaining = flow.unconfiguredKnownList
        XCTAssertEqual(remaining.map(\.url), [URL(string: "https://other.example")],
                       "endpoints already in the configured list must not appear in the add-from-known list")
    }

    func test_isPrimary_reflectsConfiguration() async throws {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }
        try await waitFor { flow.state.snapshot.configuration.primaryURL != nil }
        XCTAssertTrue(flow.isPrimary(testEndpoint))
    }

    // MARK: - validate

    func test_validate_acceptsHTTPS() {
        XCTAssertNotNil(RelayerSettingsFlow.validate("https://relayer.example.com"))
    }

    func test_validate_acceptsHTTPForLocalhost() {
        XCTAssertNotNil(RelayerSettingsFlow.validate("http://localhost:8080"))
    }

    func test_validate_rejectsEmpty() {
        XCTAssertNil(RelayerSettingsFlow.validate(""))
    }

    func test_validate_rejectsMissingScheme() {
        XCTAssertNil(RelayerSettingsFlow.validate("relayer.example.com"))
    }

    func test_validate_rejectsMissingHost() {
        XCTAssertNil(RelayerSettingsFlow.validate("https://"))
    }

    // MARK: - helpers

    private func waitFor(
        timeoutMs: Int = 1000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while !condition() {
            if Date() > deadline {
                XCTFail("waitFor timed out after \(timeoutMs)ms")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
