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

    private var cached: BlossomServersConfiguration
    private var continuations: [UUID: AsyncStream<BlossomServersConfiguration>.Continuation] = [:]

    init(store: any BlossomServersSelectionStore) {
        self.store = store
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

    /// Reset to the app-shipped default. Resets
    /// `hasUserInteracted = false` so the seed sticks even if the user
    /// later clears + relaunches.
    func resetToDefault() {
        applyConfiguration(.seed)
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
