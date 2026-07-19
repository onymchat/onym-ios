import XCTest
@testable import OnymIOS

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
