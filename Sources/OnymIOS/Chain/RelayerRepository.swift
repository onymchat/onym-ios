import Foundation

/// Combined snapshot consumed by the picker view. Two halves change
/// independently — refreshing the GitHub list is async; selection is
/// a synchronous user action — but views always want both in one go.
struct RelayerState: Equatable, Sendable {
    let selection: RelayerSelection?
    let knownList: [RelayerEndpoint]

    static let empty = RelayerState(selection: nil, knownList: [])
}

/// Owns the user's relayer choice + the cached known-relayers list.
/// Mirrors `IdentityRepository` / `IncomingInvitationsRepository`
/// shape: `actor` with snapshot replay on subscribe + a fresh push
/// after every successful mutation.
///
/// Lifecycle:
/// 1. `OnymIOSApp.init` constructs the repository with the prod
///    fetcher + UserDefaults store.
/// 2. App `.task { await repo.start() }` triggers a background fetch
///    of the latest `relayers.json`. While it's in flight, the UI
///    sees whatever was cached on disk from the last successful run.
/// 3. User taps Settings → Network → Relayer; the picker view reads
///    `snapshots`, dispatches `select` / `selectCustom` intents.
/// 4. Future chain interactors read `snapshot.selection?.url` to
///    decide where to POST.
actor RelayerRepository {
    private let fetcher: any KnownRelayersFetcher
    private let store: any RelayerSelectionStore

    private var cached: RelayerState
    private var continuations: [UUID: AsyncStream<RelayerState>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    init(fetcher: any KnownRelayersFetcher, store: any RelayerSelectionStore) {
        self.fetcher = fetcher
        self.store = store
        self.cached = RelayerState(
            selection: store.loadSelection(),
            knownList: store.loadCachedKnownList()
        )
    }

    /// Trigger a background refresh of the known-relayers list.
    /// Idempotent — a second call while the first is in flight is a
    /// no-op. Failures fall through silently; the cached list (if
    /// any) remains the source of truth, and the user can always
    /// enter a custom URL.
    func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.refreshFromNetwork()
        }
    }

    /// Force a fresh fetch (user-initiated pull-to-refresh, eventually).
    /// Awaits completion so callers can show progress UI. Failures
    /// throw so the UI can surface them.
    func refresh() async throws {
        let list = try await fetcher.fetchLatest()
        store.saveCachedKnownList(list)
        cached = RelayerState(selection: cached.selection, knownList: list)
        publish()
    }

    /// User picked one of the published relayers from the list.
    func select(_ endpoint: RelayerEndpoint) {
        let selection = RelayerSelection.known(endpoint)
        store.saveSelection(selection)
        cached = RelayerState(selection: selection, knownList: cached.knownList)
        publish()
    }

    /// User typed a custom URL (private deployment, localhost, etc.).
    func selectCustom(url: URL) {
        let selection = RelayerSelection.custom(url)
        store.saveSelection(selection)
        cached = RelayerState(selection: selection, knownList: cached.knownList)
        publish()
    }

    /// User cleared the selection (e.g. signing out of a deployment).
    func clearSelection() {
        store.saveSelection(nil)
        cached = RelayerState(selection: nil, knownList: cached.knownList)
        publish()
    }

    /// Snapshot the current state without subscribing to future ones.
    func currentState() -> RelayerState { cached }

    nonisolated var snapshots: AsyncStream<RelayerState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<RelayerState>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(cached)
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(cached)
        }
    }

    /// Internal-use refresh; swallows errors so background `start()`
    /// can't leak an exception. Public callers go through `refresh()`.
    private func refreshFromNetwork() async {
        do {
            try await refresh()
        } catch {
            // Cached list (if any) remains valid; nothing to do.
        }
    }
}
