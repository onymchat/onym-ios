import Foundation
import XCTest
@testable import OnymDiscovery

/// The add-provider sub-flow of `DiscoverySettingsFlow` — specifically
/// that dismissing the sheet (`resetAdd`) invalidates an in-flight
/// fetch, so its later completion can never resurrect the phase the
/// user already walked away from.
final class DiscoverySettingsFlowTests: XCTestCase {
    private let manifestURL = URL(string: "https://discovery.onym.app/manifest.json")!

    /// Suspends manifest fetches until the gate opens — holds the
    /// add-provider fetch mid-flight deterministically.
    private actor FetchGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private final class GatedFetcher: DiscoveryFetching, @unchecked Sendable {
        let gate = FetchGate()
        private let responses: [URL: Data]
        private let lock = NSLock()
        private var _manifestFetchCount = 0

        var manifestFetchCount: Int {
            lock.withLock { _manifestFetchCount }
        }

        init(responses: [URL: Data]) {
            self.responses = responses
        }

        func fetchProviderManifest(url: URL) async throws -> Data {
            lock.withLock { _manifestFetchCount += 1 }
            await gate.wait()
            guard let data = responses[url] else { throw DiscoveryFetchError.badStatus(404) }
            return data
        }

        func fetchSnapshot(url: URL) async throws -> Data {
            guard let data = responses[url] else { throw DiscoveryFetchError.badStatus(404) }
            return data
        }
    }

    /// In-memory store; no UserDefaults so tests stay hermetic.
    private final class MemoryStore: DiscoveryStore, @unchecked Sendable {
        private let lock = NSLock()
        private var configuration: DiscoverySourcesConfiguration = .empty
        private var snapshots: [String: Data] = [:]

        func loadConfiguration() -> DiscoverySourcesConfiguration {
            lock.withLock { configuration }
        }
        func saveConfiguration(_ configuration: DiscoverySourcesConfiguration) {
            lock.withLock { self.configuration = configuration }
        }
        func loadRetainedSnapshot(providerId: String, catalogId: String) -> Data? {
            lock.withLock { snapshots[providerId + "|" + catalogId] }
        }
        func saveRetainedSnapshot(_ raw: Data, providerId: String, catalogId: String) {
            lock.withLock { snapshots[providerId + "|" + catalogId] = raw }
        }
        func removeRetainedSnapshots(providerId: String) {
            lock.withLock {
                snapshots = snapshots.filter { !$0.key.hasPrefix(providerId + "|") }
            }
        }
    }

    private let snapshotURL = URL(string: "https://discovery.onym.app/catalogs/public-all-seats.json")!

    @MainActor
    private func makeFlow() throws -> (DiscoverySettingsFlow, GatedFetcher, MemoryStore) {
        let fetcher = GatedFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let store = MemoryStore()
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }
        return (DiscoverySettingsFlow(repository: repository), fetcher, store)
    }

    /// Wait until the flow's fetch task has actually reached the
    /// fetcher (bounded, so a regression fails rather than hangs).
    private func waitForFetchStart(_ fetcher: GatedFetcher) async throws {
        for _ in 0..<1_000 {
            if fetcher.manifestFetchCount > 0 { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("add-provider fetch never started")
    }

    /// Control case: with no reset, the held fetch completes into
    /// `.confirming` — proves the gate harness exercises the real path.
    @MainActor
    func testFetchCompletesIntoConfirming() async throws {
        let (flow, fetcher, _) = try makeFlow()
        flow.addDraft = manifestURL.absoluteString
        flow.tappedFetchProvider()
        guard case .fetching = flow.addPhase else {
            return XCTFail("expected .fetching, got \(flow.addPhase)")
        }
        try await waitForFetchStart(fetcher)

        await fetcher.gate.open()
        await flow.addTask?.value

        guard case .confirming(let preview) = flow.addPhase else {
            return XCTFail("expected .confirming, got \(flow.addPhase)")
        }
        XCTAssertEqual(preview.providerId, "onym:component:onym-discovery")
    }

    /// The reviewed regression: dismissing the sheet while the fetch
    /// is in flight must invalidate it — the stale completion must not
    /// flip a reset flow back to `.confirming` (or clobber the state
    /// of a NEW fetch started afterwards).
    @MainActor
    func testResetDuringFetchDoesNotResurrectConfirming() async throws {
        let (flow, fetcher, _) = try makeFlow()
        flow.addDraft = manifestURL.absoluteString
        flow.tappedFetchProvider()
        try await waitForFetchStart(fetcher)
        let inFlight = try XCTUnwrap(flow.addTask)

        flow.resetAdd()
        guard case .idle = flow.addPhase else {
            return XCTFail("reset must return the sheet to .idle")
        }
        XCTAssertNil(flow.addTask, "reset must drop (and cancel) the in-flight fetch")

        // Let the superseded fetch run to completion.
        await fetcher.gate.open()
        await inFlight.value

        guard case .idle = flow.addPhase else {
            return XCTFail("stale completion resurrected \(flow.addPhase) after reset")
        }
        XCTAssertNil(flow.addError)
        XCTAssertEqual(flow.addDraft, "")
    }

    /// Drive the flow to the `.confirming` TOFU step (gate opened).
    @MainActor
    private func reachConfirming(_ flow: DiscoverySettingsFlow, _ fetcher: GatedFetcher) async throws {
        flow.addDraft = manifestURL.absoluteString
        flow.tappedFetchProvider()
        try await waitForFetchStart(fetcher)
        await fetcher.gate.open()
        await flow.addTask?.value
        guard case .confirming = flow.addPhase else {
            XCTFail("expected .confirming, got \(flow.addPhase)")
            throw CancellationError()
        }
    }

    /// Control case for the confirm path: an undisturbed confirm pins
    /// the source, reaches `.added`, and the targeted refresh lands
    /// the source's catalog entries in the aggregate.
    @MainActor
    func testConfirmCompletesIntoAddedAndFetchesTheSource() async throws {
        let (flow, fetcher, store) = try makeFlow()
        flow.start()
        try await reachConfirming(flow, fetcher)

        flow.tappedConfirmAdd()
        await flow.confirmTask?.value

        guard case .added = flow.addPhase else {
            return XCTFail("expected .added, got \(flow.addPhase)")
        }
        XCTAssertEqual(store.loadConfiguration().sources.count, 1)
        XCTAssertNotNil(store.loadConfiguration().sources.first?.pinnedOperatorKeyHex)
        XCTAssertNotNil(
            store.loadRetainedSnapshot(
                providerId: "onym:component:onym-discovery",
                catalogId: "public-all-seats"
            ),
            "the confirm's targeted refresh must fetch the source's catalogs"
        )
    }

    /// Double-tapping Confirm while the first confirm is still in
    /// flight must be a no-op: the phase stays `.confirming` until the
    /// task finishes, so without the in-flight guard the second tap
    /// would run the whole pin + targeted-refresh pipeline again.
    ///
    /// Deterministic (no sleep): both taps happen synchronously on the
    /// main actor before either confirm task can run, and BOTH task
    /// handles observed across the taps are awaited — if a buggy
    /// second tap spawned its own pipeline, `confirmTask` would be a
    /// different task, awaiting it would run that pipeline to
    /// completion, and the fetch count would deterministically read 3.
    @MainActor
    func testDoubleTapConfirmRunsThePipelineOnce() async throws {
        let (flow, fetcher, store) = try makeFlow()
        try await reachConfirming(flow, fetcher)
        XCTAssertEqual(fetcher.manifestFetchCount, 1, "the preview fetch")

        flow.tappedConfirmAdd()
        let firstConfirm = flow.confirmTask
        flow.tappedConfirmAdd() // double tap before the first task runs
        let taskAfterSecondTap = flow.confirmTask

        await firstConfirm?.value
        await taskAfterSecondTap?.value

        guard case .added = flow.addPhase else {
            return XCTFail("expected .added, got \(flow.addPhase)")
        }
        XCTAssertEqual(
            fetcher.manifestFetchCount, 2,
            "one preview fetch + ONE targeted refresh — a double tap must not run a second confirm"
        )
        XCTAssertEqual(store.loadConfiguration().sources.count, 1)
    }

    /// The round-4 continuation-leak regression: `stop()` (wired to
    /// the view's `onDisappear`) must cancel the snapshot drain, and
    /// the cancellation must remove the drain's continuation from the
    /// repository — otherwise every settings-screen visit would leave
    /// one behind (the stream never finishes on its own) and pin the
    /// flow forever.
    @MainActor
    func testStopRemovesTheSnapshotContinuationFromTheRepository() async throws {
        let fetcher = GatedFetcher(responses: [:])
        let repository = DiscoveryRepository(fetcher: fetcher, store: MemoryStore()) { Fixture.now }
        let flow = DiscoverySettingsFlow(repository: repository)

        flow.start()
        try await waitFor("the drain to subscribe") {
            await repository.subscriberCount == 1
        }

        flow.stop()
        try await waitFor("the cancelled drain's continuation to be removed") {
            await repository.subscriberCount == 0
        }
    }

    /// Bounded poll so a regression fails rather than hangs.
    private func waitFor(
        _ what: String,
        _ condition: () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// The reviewed regression on the CONFIRM path: dismissing the
    /// sheet mid-confirm must not set `.added` afterwards — reopening
    /// Add would otherwise show a stale "Provider added" screen. The
    /// pin itself still completes (the user explicitly confirmed it).
    @MainActor
    func testResetDuringConfirmDoesNotSetAdded() async throws {
        let (flow, fetcher, store) = try makeFlow()
        try await reachConfirming(flow, fetcher)

        flow.tappedConfirmAdd()
        // Dismiss the sheet before the confirm task runs.
        flow.resetAdd()
        await flow.confirmTask?.value

        guard case .idle = flow.addPhase else {
            return XCTFail("dismiss mid-confirm must not surface \(flow.addPhase)")
        }
        // The explicit confirmation is still honored durably.
        XCTAssertEqual(store.loadConfiguration().sources.count, 1)
        XCTAssertNotNil(store.loadConfiguration().sources.first?.pinnedOperatorKeyHex)
    }

    /// The fifth-review regression, exact sequence: Confirm → Back
    /// (cancel preview) → type a URL → Fetch → Confirm. The in-flight
    /// guard must clear when the first confirm task finishes (defer),
    /// or the second Confirm is a permanent silent no-op; and Back
    /// must bump the generation, so the superseded confirm's
    /// completion never surfaces `.added` over the new cycle.
    @MainActor
    func testConfirmThenBackThenNewFetchCanConfirmAgain() async throws {
        let (flow, fetcher, store) = try makeFlow()
        try await reachConfirming(flow, fetcher)

        flow.tappedConfirmAdd()
        let firstConfirm = flow.confirmTask
        // Back out of the preview before the confirm task runs.
        flow.tappedCancelPreview()
        guard case .idle = flow.addPhase else {
            return XCTFail("Back must return the sheet to .idle, got \(flow.addPhase)")
        }
        await firstConfirm?.value
        guard case .idle = flow.addPhase else {
            return XCTFail("the superseded confirm resurrected \(flow.addPhase) after Back")
        }
        // The pin the user explicitly confirmed still completed.
        XCTAssertEqual(store.loadConfiguration().sources.count, 1)

        // A fresh URL → Fetch → Confirm cycle must be live, not a
        // silent no-op left behind by the first confirm's guard.
        flow.addDraft = manifestURL.absoluteString
        flow.tappedFetchProvider()
        await flow.addTask?.value
        guard case .confirming = flow.addPhase else {
            return XCTFail("expected .confirming for the new fetch, got \(flow.addPhase)")
        }
        flow.tappedConfirmAdd()
        XCTAssertNotNil(flow.confirmTask, "the second Confirm must start a confirm task")
        await flow.confirmTask?.value
        guard case .added = flow.addPhase else {
            return XCTFail("the second Confirm must complete into .added, got \(flow.addPhase)")
        }
        XCTAssertEqual(store.loadConfiguration().sources.count, 1,
                       "re-confirming the same provider replaces the source in place")
    }
}
