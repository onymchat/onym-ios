import XCTest
@testable import OnymIOS

/// Picker flow against a real `ContractsRepository` backed by the
/// in-memory fakes. Asserts the read-helper rules (default-to-latest
/// vs explicit-selection rendering, mainnet-disabled gating) and the
/// intent → repository → snapshot pipeline.
@MainActor
final class AnchorsPickerFlowTests: XCTestCase {

    private static let v002 = ContractRelease(
        release: "v0.0.2",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_002),
        contracts: [
            ContractEntry(network: .testnet, type: .anarchy, id: "CDWYYK..."),
        ]
    )
    private static let v001 = ContractRelease(
        release: "v0.0.1",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_001),
        contracts: [
            ContractEntry(network: .testnet, type: .anarchy, id: "CDSIJT..."),
        ]
    )
    private static let manifest = ContractsManifest(version: 1, releases: [v002, v001])

    private let testnetAnarchy = AnchorSelectionKey(network: .testnet, type: .anarchy)
    private let mainnetAnarchy = AnchorSelectionKey(network: .public, type: .anarchy)

    private func makeFlow(
        store: InMemoryAnchorSelectionStore? = nil
    ) -> (AnchorsPickerFlow, ContractsRepository) {
        let resolvedStore = store ?? InMemoryAnchorSelectionStore(manifest: Self.manifest)
        let fetcher = FakeContractsManifestFetcher(mode: .succeeds(.empty))
        let repo = ContractsRepository(fetcher: fetcher, store: resolvedStore)
        let flow = AnchorsPickerFlow(repository: repo)
        return (flow, repo)
    }

    // MARK: - read helpers

    func test_binding_returnsLatestWhenNoExplicitSelection() async throws {
        let (flow, _) = makeFlow()
        flow.start()
        defer { flow.stop() }
        try await waitForState(flow: flow) { !$0.manifest.releases.isEmpty }
        XCTAssertEqual(flow.binding(for: testnetAnarchy)?.release, "v0.0.2")
    }

    func test_binding_returnsExplicitSelectionWhenSet() async throws {
        let store = InMemoryAnchorSelectionStore(
            selections: [testnetAnarchy: "v0.0.1"],
            manifest: Self.manifest
        )
        let (flow, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }
        try await waitForState(flow: flow) { $0.selections[self.testnetAnarchy] == "v0.0.1" }
        XCTAssertEqual(flow.binding(for: testnetAnarchy)?.release, "v0.0.1")
    }

    func test_hasExplicitSelection_reflectsStore() async throws {
        let store = InMemoryAnchorSelectionStore(
            selections: [testnetAnarchy: "v0.0.1"],
            manifest: Self.manifest
        )
        let (flow, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }
        try await waitForState(flow: flow) { !$0.selections.isEmpty }
        XCTAssertTrue(flow.hasExplicitSelection(for: testnetAnarchy))
        XCTAssertFalse(flow.hasExplicitSelection(
            for: AnchorSelectionKey(network: .testnet, type: .democracy)
        ))
    }

    func test_hasAnyContracts_trueForTestnet_falseForMainnet() async throws {
        let (flow, _) = makeFlow()
        flow.start()
        defer { flow.stop() }
        try await waitForState(flow: flow) { !$0.manifest.releases.isEmpty }
        XCTAssertTrue(flow.hasAnyContracts(network: .testnet))
        XCTAssertFalse(flow.hasAnyContracts(network: .public),
                       "manifest only has testnet contracts → mainnet row stays disabled")
    }

    func test_availableReleases_newestFirst() async throws {
        let (flow, _) = makeFlow()
        flow.start()
        defer { flow.stop() }
        try await waitForState(flow: flow) { !$0.manifest.releases.isEmpty }
        let releases = flow.availableReleases(for: testnetAnarchy)
        XCTAssertEqual(releases.map(\.release), ["v0.0.2", "v0.0.1"])
    }

    // MARK: - intents

    func test_tappedVersion_persistsViaRepository() async throws {
        let store = InMemoryAnchorSelectionStore(manifest: Self.manifest)
        let (flow, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedVersion(key: testnetAnarchy, releaseTag: "v0.0.1")
        try await waitFor { store.loadSelections()[self.testnetAnarchy] == "v0.0.1" }
        XCTAssertEqual(flow.binding(for: testnetAnarchy)?.release, "v0.0.1")
    }

    func test_tappedResetToDefault_clearsExplicitAndFallsBackToLatest() async throws {
        let store = InMemoryAnchorSelectionStore(
            selections: [testnetAnarchy: "v0.0.1"],
            manifest: Self.manifest
        )
        let (flow, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }
        try await waitForState(flow: flow) { $0.selections[self.testnetAnarchy] == "v0.0.1" }

        flow.tappedResetToDefault(key: testnetAnarchy)
        try await waitFor { store.loadSelections()[self.testnetAnarchy] == nil }
        XCTAssertEqual(flow.binding(for: testnetAnarchy)?.release, "v0.0.2",
                       "after reset → default-to-latest")
    }

    // MARK: - helpers

    private func waitForState(
        flow: AnchorsPickerFlow,
        timeoutMs: Int = 1000,
        _ predicate: @escaping @MainActor (ContractsState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while !predicate(flow.state) {
            if Date() > deadline {
                XCTFail("waitForState timed out after \(timeoutMs)ms")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

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
