import Foundation

/// Owns the user's Blossom-server configuration. Mirrors
/// `NostrRelaysRepository`: `actor` with snapshot replay on subscribe +
/// a fresh push after every mutation.
///
/// Lifecycle:
///   1. `OnymIOSApp.init` constructs the repository with the
///      UserDefaults-backed store.
///   2. On init, if the persisted config is empty and the user hasn't
///      interacted yet, seed with `.seed` (Onym's official Blossom
///      server). Subsequent launches restore the user's actual list.
///   3. App boot reads `currentEndpoints()` once and points the
///      `URLSessionBlossomClient` base URL at the first configured
///      server (uploads + downloads).
///   4. Settings → Transport → Blossom drives `addEndpoint` /
///      `removeEndpoint`. Changes apply on the next app launch (V1
///      doesn't rebuild the client live — Settings shows a banner).
actor BlossomServersRepository {
    private let store: any BlossomServersSelectionStore
    /// Fetches the Onym-published default list from GitHub. `nil` disables
    /// network refresh entirely (UI tests / offline builds) — the
    /// hardcoded seed then remains the only default.
    private let fetcher: (any KnownBlossomServersFetcher)?

    private var cached: BlossomServersConfiguration
    private var continuations: [UUID: AsyncStream<BlossomServersConfiguration>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    init(store: any BlossomServersSelectionStore, fetcher: (any KnownBlossomServersFetcher)? = nil) {
        self.store = store
        self.fetcher = fetcher
        let loaded = store.load()
        // First-launch seed: empty config + no prior user interaction
        // → install the app's default server. Sticky once the user
        // touches the list (mutations flip `hasUserInteracted`).
        if loaded.endpoints.isEmpty && !loaded.hasUserInteracted {
            self.cached = .seed
            store.save(.seed)
        } else {
            self.cached = loaded
        }
    }

    // MARK: - Read

    /// Snapshot of the configured servers. Read at app boot to pick the
    /// blob upload/download base URL.
    func currentEndpoints() -> [BlossomServerEndpoint] {
        cached.endpoints
    }

    func currentConfiguration() -> BlossomServersConfiguration {
        cached
    }

    // MARK: - Network refresh

    /// Fetch the published default list once, in the background. Idempotent.
    /// Called at app boot; no-op when no fetcher is configured.
    func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.refreshFromNetwork()
        }
    }

    /// Fetch the published list and, while the user hasn't customised
    /// their own (`hasUserInteracted == false`), install it as the new
    /// default. Throws on fetch failure — the current cached config
    /// (hardcoded seed or last good fetch) stays intact.
    func refresh() async throws {
        guard let fetcher else { return }
        let list = try await fetcher.fetchLatest()
        guard !cached.hasUserInteracted, !list.isEmpty else { return }
        applyDefault(endpoints: list)
    }

    private func refreshFromNetwork() async {
        try? await refresh()
    }

    // MARK: - Mutations

    /// Idempotent on URL — re-adding an existing URL replaces its
    /// metadata (display name) but doesn't duplicate the row.
    /// Returns true on insert, false on update.
    @discardableResult
    func addEndpoint(_ endpoint: BlossomServerEndpoint) -> Bool {
        var endpoints = cached.endpoints
        let inserted: Bool
        if let index = endpoints.firstIndex(where: { $0.url == endpoint.url }) {
            endpoints[index] = endpoint
            inserted = false
        } else {
            endpoints.append(endpoint)
            inserted = true
        }
        applyConfiguration(BlossomServersConfiguration(
            endpoints: endpoints,
            hasUserInteracted: true
        ))
        return inserted
    }

    func removeEndpoint(url: URL) {
        let endpoints = cached.endpoints.filter { $0.url != url }
        applyConfiguration(BlossomServersConfiguration(
            endpoints: endpoints,
            hasUserInteracted: true
        ))
    }

    /// Drop every entry. Sets `hasUserInteracted = true` so the next
    /// launch doesn't re-seed.
    func clearAll() {
        applyConfiguration(BlossomServersConfiguration(
            endpoints: [],
            hasUserInteracted: true
        ))
    }

    /// Restore the Onym-published default. Re-fetches the latest list from
    /// GitHub and installs it; on any failure (offline / bad response /
    /// empty / no fetcher) falls back to the hardcoded `.seed`. Either way
    /// `hasUserInteracted` returns to `false` so the default sticks and a
    /// future launch re-refreshes.
    func resetToDefault() async {
        if let fetcher {
            do {
                let list = try await fetcher.fetchLatest()
                if !list.isEmpty {
                    applyDefault(endpoints: list)
                    return
                }
            } catch {
                // Offline / bad response — fall through to the seed.
            }
        }
        applyConfiguration(.seed)
    }

    /// Install `endpoints` as the current default: persists with
    /// `hasUserInteracted = false` so it's still treated as "the default".
    private func applyDefault(endpoints: [BlossomServerEndpoint]) {
        applyConfiguration(BlossomServersConfiguration(
            endpoints: endpoints,
            hasUserInteracted: false
        ))
    }

    // MARK: - Subscriptions

    nonisolated var snapshots: AsyncStream<BlossomServersConfiguration> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func applyConfiguration(_ configuration: BlossomServersConfiguration) {
        store.save(configuration)
        cached = configuration
        publish()
    }

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<BlossomServersConfiguration>.Continuation
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
}
