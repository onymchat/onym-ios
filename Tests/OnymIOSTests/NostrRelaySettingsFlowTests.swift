import XCTest
@testable import OnymIOS

@MainActor
final class NostrRelaySettingsFlowTests: XCTestCase {

    func test_validate_acceptsWssAndWs() {
        XCTAssertNotNil(NostrRelaySettingsFlow.validate("wss://relay.example.com"))
        XCTAssertNotNil(NostrRelaySettingsFlow.validate("ws://localhost:7777"))
    }

    func test_validate_rejectsHttpAndBareString() {
        XCTAssertNil(NostrRelaySettingsFlow.validate("https://relay.example.com"),
                     "https not accepted — Nostr is WebSocket-only")
        XCTAssertNil(NostrRelaySettingsFlow.validate("relay.example.com"),
                     "no scheme not accepted")
        XCTAssertNil(NostrRelaySettingsFlow.validate(""))
        XCTAssertNil(NostrRelaySettingsFlow.validate("wss://"),
                     "missing host not accepted")
    }

    func test_tappedAddCustom_invalidURL_setsErrorAndKeepsDraft() async throws {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        let flow = NostrRelaySettingsFlow(repository: repo)
        flow.customDraftChanged("https://wrong-scheme")
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertEqual(flow.state.customDraft, "https://wrong-scheme",
                       "draft must be kept so the user can edit")
    }

    func test_tappedAddCustom_validURL_clearsDraftAndAdds() async throws {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        let flow = NostrRelaySettingsFlow(repository: repo)
        flow.customDraftChanged("wss://relay.example.com")
        flow.tappedAddCustom()
        // Draft cleared synchronously on success.
        XCTAssertEqual(flow.state.customDraft, "")
        XCTAssertNil(flow.state.customDraftError)
        // Repo mutation goes through Task — wait briefly.
        try await Task.sleep(nanoseconds: 50_000_000)
        let endpoints = await repo.currentEndpoints()
        XCTAssertTrue(endpoints.contains { $0.url.absoluteString == "wss://relay.example.com" })
    }

    func test_start_drainsRepositorySnapshotsIntoState() async throws {
        let store = InMemoryNostrRelaysSelectionStore(initial: .empty)
        let repo = NostrRelaysRepository(store: store)
        let flow = NostrRelaySettingsFlow(repository: repo)
        flow.start()
        try await waitFor { flow.state.snapshot.endpoints.count == 1 }
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
