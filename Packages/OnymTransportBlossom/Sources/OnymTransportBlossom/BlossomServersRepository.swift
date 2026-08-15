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
///   3. The app's `DynamicBaseURLBlossomClient` re-reads
///      `currentEndpoints()` per operation and targets the first
///      configured server (uploads + downloads).
///   4. Settings → Transport → Blossom drives `addEndpoint` /
///      `removeEndpoint`. Changes apply to the very next
///      upload/download — no relaunch needed.
public actor BlossomServersRepository {
    private let store: any BlossomServersSelectionStore
    /// Fetches the Onym-published default list from GitHub. `nil` disables
    /// network refresh entirely (UI tests / offline builds) — the
    /// hardcoded seed then remains the only default.
    private let fetcher: (any KnownBlossomServersFetcher)?

    private var cached: BlossomServersConfiguration
    private var continuations: [UUID: AsyncStream<BlossomServersConfiguration>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    public init(store: any BlossomServersSelectionStore, fetcher: (any KnownBlossomServersFetcher)? = nil) {
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
    public func currentEndpoints() -> [BlossomServerEndpoint] {
        cached.endpoints
    }

    func currentConfiguration() -> BlossomServersConfiguration {
        cached
    }

    // MARK: - Network refresh

    /// Fetch the published default list once, in the background. Idempotent.
    /// Called at app boot; no-op when no fetcher is configured.
    public func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.refreshFromNetwork()
        }
    }

    /// Fetch the published list and, while the user hasn't customised
    /// their own (`hasUserInteracted == false`), install it as the new
    /// default. Throws on fetch failure — the current cached config
    /// (hardcoded seed or last good fetch) stays intact.
    public func refresh() async throws {
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
    ///
    /// `makeActive: true` places the endpoint at the HEAD of the list
    /// (moving it there when it already exists). The first endpoint is
    /// the one uploads/downloads target, so this is how a pick — e.g.
    /// a consented catalog module — actually takes effect; a plain
    /// append behind the seeded default would be silently inert.
    /// Other entries keep their relative order.
    @discardableResult
    public func addEndpoint(_ endpoint: BlossomServerEndpoint, makeActive: Bool = false) -> Bool {
        var endpoints = cached.endpoints
        let inserted: Bool
        if let index = endpoints.firstIndex(where: { $0.url == endpoint.url }) {
            if makeActive {
                endpoints.remove(at: index)
                endpoints.insert(endpoint, at: 0)
            } else {
                endpoints[index] = endpoint
            }
            inserted = false
        } else {
            if makeActive {
                endpoints.insert(endpoint, at: 0)
            } else {
                endpoints.append(endpoint)
            }
            inserted = true
        }
        applyConfiguration(BlossomServersConfiguration(
            endpoints: endpoints,
            hasUserInteracted: true
        ))
        return inserted
    }

    /// Move the configured endpoint with `url` to the head of the list
    /// so it becomes the upload/download target. No-op when the URL
    /// isn't configured (callers add first) or is already active — in
    /// both cases nothing is persisted and `hasUserInteracted` is left
    /// alone. An actual move counts as a user mutation.
    public func makeActive(url: URL) {
        guard let index = cached.endpoints.firstIndex(where: { $0.url == url }),
              index != 0
        else { return }
        var endpoints = cached.endpoints
        let endpoint = endpoints.remove(at: index)
        endpoints.insert(endpoint, at: 0)
        applyConfiguration(BlossomServersConfiguration(
            endpoints: endpoints,
            hasUserInteracted: true
        ))
    }

    public func removeEndpoint(url: URL) {
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
    public func resetToDefault() async {
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

    public nonisolated var snapshots: AsyncStream<BlossomServersConfiguration> {
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
