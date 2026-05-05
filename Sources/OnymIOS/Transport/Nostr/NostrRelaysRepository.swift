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

    private var cached: NostrRelaysConfiguration
    private var continuations: [UUID: AsyncStream<NostrRelaysConfiguration>.Continuation] = [:]

    init(store: any NostrRelaysSelectionStore) {
        self.store = store
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

    /// Reset to the app-shipped default. Useful as a "restore
    /// defaults" affordance in Settings; resets
    /// `hasUserInteracted = false` so the seed sticks even if the
    /// user later clears + relaunches.
    func resetToDefault() {
        applyConfiguration(.seed)
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
