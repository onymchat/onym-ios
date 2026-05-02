import XCTest
@testable import OnymIOS

/// Picker flow against a real `RelayerRepository` backed by the
/// in-memory store + fake fetcher. Asserts the intent → repository
/// → snapshot → state pipeline plus the local-only custom-URL draft
/// + validation.
@MainActor
final class RelayerPickerFlowTests: XCTestCase {
    private let testEndpoint = RelayerEndpoint(
        name: "Test",
        url: URL(string: "https://relayer-test.example")!,
        network: "testnet"
    )

    private func makeFlow(
        store: InMemoryRelayerSelectionStore = InMemoryRelayerSelectionStore(),
        fetcherMode: FakeKnownRelayersFetcher.Mode = .succeeds([])
    ) -> (RelayerPickerFlow, RelayerRepository, InMemoryRelayerSelectionStore) {
        let fetcher = FakeKnownRelayersFetcher(mode: fetcherMode)
        let repo = RelayerRepository(fetcher: fetcher, store: store)
        let flow = RelayerPickerFlow(repository: repo)
        return (flow, repo, store)
    }

    // MARK: - intents

    func test_tappedKnownRelayer_persistsViaRepository() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.tappedKnownRelayer(testEndpoint)
        try await waitFor { store.loadSelection() != nil }
        XCTAssertEqual(store.loadSelection(), .known(testEndpoint))
    }

    func test_tappedClearSelection_clearsViaRepository() async throws {
        let store = InMemoryRelayerSelectionStore(selection: .known(testEndpoint))
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedClearSelection()
        try await waitFor { store.loadSelection() == nil }
        XCTAssertNil(store.loadSelection())
    }

    // MARK: - custom URL draft

    func test_customDraftChanged_updatesStateAndClearsError() {
        let (flow, _, _) = makeFlow()
        // Drive an error onto the state via the public API (empty
        // save fails validation), then assert that the next
        // customDraftChanged clears it.
        flow.tappedSaveCustom()
        XCTAssertNotNil(flow.state.customDraftError, "precondition: error must be set")

        flow.customDraftChanged("https://x.com")
        XCTAssertEqual(flow.state.customDraft, "https://x.com")
        XCTAssertNil(flow.state.customDraftError)
    }

    func test_tappedSaveCustom_validURL_persistsViaRepository() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.customDraftChanged("https://my-relayer.dev")
        flow.tappedSaveCustom()
        try await waitFor { store.loadSelection() != nil }
        XCTAssertEqual(store.loadSelection(), .custom(URL(string: "https://my-relayer.dev")!))
        XCTAssertNil(flow.state.customDraftError)
    }

    func test_tappedSaveCustom_emptyDraft_setsError() {
        let (flow, _, store) = makeFlow()
        flow.customDraftChanged("")
        flow.tappedSaveCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertNil(store.loadSelection())
    }

    func test_tappedSaveCustom_garbageDraft_setsError() {
        let (flow, _, store) = makeFlow()
        flow.customDraftChanged("not-a-url at all")
        flow.tappedSaveCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertNil(store.loadSelection())
    }

    func test_tappedSaveCustom_ftpScheme_setsError() {
        // Reject non-http(s) schemes — the relayer is HTTP.
        let (flow, _, store) = makeFlow()
        flow.customDraftChanged("ftp://relayer.example.com")
        flow.tappedSaveCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertNil(store.loadSelection())
    }

    func test_tappedSaveCustom_trimsWhitespace() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.customDraftChanged("   https://relayer.example.com  \n")
        flow.tappedSaveCustom()
        try await waitFor { store.loadSelection() != nil }
        XCTAssertEqual(
            store.loadSelection(),
            .custom(URL(string: "https://relayer.example.com")!)
        )
    }

    // MARK: - URL validation

    func test_validate_acceptsHTTPS() {
        XCTAssertNotNil(RelayerPickerFlow.validate("https://relayer.example.com"))
    }

    func test_validate_acceptsHTTPForLocalhost() {
        XCTAssertNotNil(RelayerPickerFlow.validate("http://localhost:8080"))
    }

    func test_validate_rejectsEmpty() {
        XCTAssertNil(RelayerPickerFlow.validate(""))
    }

    func test_validate_rejectsMissingScheme() {
        XCTAssertNil(RelayerPickerFlow.validate("relayer.example.com"))
    }

    func test_validate_rejectsMissingHost() {
        XCTAssertNil(RelayerPickerFlow.validate("https://"))
    }

    // MARK: - snapshot prefill

    func test_start_prefillsCustomDraftFromExistingCustomSelection() async throws {
        let url = URL(string: "https://existing-custom.dev")!
        let store = InMemoryRelayerSelectionStore(selection: .custom(url))
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        try await waitFor { flow.state.customDraft == url.absoluteString }
        XCTAssertEqual(flow.state.customDraft, url.absoluteString)
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
