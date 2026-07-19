import Foundation

/// Owns the user's Nostr-relay configuration. Mirrors
/// `RelayerRepository` shape: `actor` with snapshot replay on
/// subscribe + a fresh push after every mutation.
///
/// Lifecycle:
///   1. `OnymIOSApp.init` constructs the repository with the
///      UserDefaults-backed store.
///   2. On init, if the persisted config is empty and the user
///      hasn't interacted yet, seed with `.seed` (Onym's official
///      relay). This is the "first launch" path; subsequent launches
///      restore the user's actual list (which may be empty if they
///      removed every entry — `hasUserInteracted = true` keeps it
///      that way).
///   3. App `.task` reads `currentEndpoints()` once at boot and
///      passes them to `NostrInboxTransport.connect(to:)`.
///   4. Settings → Transport → Nostr drives `addEndpoint` /
///      `removeEndpoint`. Changes apply on the next app launch
///      (V1 doesn't reactively reconnect — Settings shows a banner).
actor NostrRelaysRepository {
    private let store: any NostrRelaysSelectionStore
    /// Fetches the Onym-published default list from GitHub. `nil` disables
    /// network refresh entirely (UI tests / offline builds) — the
    /// hardcoded seed then remains the only default.
    private let fetcher: (any KnownNostrRelaysFetcher)?

    private var cached: NostrRelaysConfiguration
    private var continuations: [UUID: AsyncStream<NostrRelaysConfiguration>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    init(store: any NostrRelaysSelectionStore, fetcher: (any KnownNostrRelaysFetcher)? = nil) {
        self.store = store
        self.fetcher = fetcher
        let loaded = store.load()
        // First-launch seed: empty config + no prior user interaction
        // → install the app's default relay. Sticky once the user
        // touches the list (mutations flip `hasUserInteracted`).
        if loaded.endpoints.isEmpty && !loaded.hasUserInteracted {
            self.cached = .seed
            store.save(.seed)
        } else {
            self.cached = loaded
        }
    }

    // MARK: - Read

    /// Snapshot of the configured endpoints. Used at app boot to
    /// pass into `NostrInboxTransport.connect(to:)`.
    func currentEndpoints() -> [NostrRelayEndpoint] {
        cached.endpoints
    }

    func currentConfiguration() -> NostrRelaysConfiguration {
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
    /// default (kept as default so a later launch re-refreshes). Throws on
    /// fetch failure — the current cached config (hardcoded seed or last
    /// good fetch) stays intact.
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
    func addEndpoint(_ endpoint: NostrRelayEndpoint) -> Bool {
        var endpoints = cached.endpoints
        let inserted: Bool
        if let index = endpoints.firstIndex(where: { $0.url == endpoint.url }) {
            endpoints[index] = endpoint
            inserted = false
        } else {
            endpoints.append(endpoint)
            inserted = true
        }
        applyConfiguration(NostrRelaysConfiguration(
            endpoints: endpoints,
            hasUserInteracted: true
        ))
        return inserted
    }

    func removeEndpoint(url: URL) {
        let endpoints = cached.endpoints.filter { $0.url != url }
        applyConfiguration(NostrRelaysConfiguration(
            endpoints: endpoints,
            hasUserInteracted: true
        ))
    }

    /// Drop every entry. Sets `hasUserInteracted = true` so the next
    /// launch doesn't re-seed.
    func clearAll() {
        applyConfiguration(NostrRelaysConfiguration(
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
    private func applyDefault(endpoints: [NostrRelayEndpoint]) {
        applyConfiguration(NostrRelaysConfiguration(
            endpoints: endpoints,
            hasUserInteracted: false
        ))
    }

    // MARK: - Subscriptions

    nonisolated var snapshots: AsyncStream<NostrRelaysConfiguration> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func applyConfiguration(_ configuration: NostrRelaysConfiguration) {
        store.save(configuration)
        cached = configuration
        publish()
    }

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<NostrRelaysConfiguration>.Continuation
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
