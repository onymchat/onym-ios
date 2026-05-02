import Foundation

/// Combined snapshot consumed by the picker view. Three halves change
/// independently — refreshing the GitHub list is async; configuration
/// changes are synchronous user actions — but views always want them
/// in one go.
struct RelayerState: Equatable, Sendable {
    let configuration: RelayerConfiguration
    let knownList: [RelayerEndpoint]

    static let empty = RelayerState(configuration: .empty, knownList: [])
}

/// Owns the user's relayer configuration (multiple endpoints, primary
/// marker, strategy) + the cached known-relayers list. Mirrors
/// `IdentityRepository` shape: `actor` with snapshot replay on
/// subscribe + a fresh push after every successful mutation.
///
/// Lifecycle:
/// 1. `OnymIOSApp.init` constructs the repository with prod fetcher +
///    UserDefaults store.
/// 2. App `.task { await repo.start() }` triggers a background fetch
///    of the latest `relayers.json`. While in flight, the UI sees
///    whatever was cached on disk from the last successful run.
/// 3. User opens Settings → Network → Relayer; the settings view
///    dispatches add/remove/setPrimary/setStrategy intents.
/// 4. Future chain interactors call `selectURL()` for the URL to POST
///    to per request — strategy decides primary vs random.
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
            configuration: store.loadConfiguration(),
            knownList: store.loadCachedKnownList()
        )
    }

    // MARK: - Background refresh

    /// Trigger a background refresh of the known-relayers list.
    /// Idempotent — a second call while the first is in flight is a
    /// no-op. Failures fall through silently; the cached list (if any)
    /// remains the source of truth.
    func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.refreshFromNetwork()
        }
    }

    /// Force a fresh fetch (user-initiated pull-to-refresh, eventually).
    /// Awaits completion so callers can show progress UI. Failures
    /// throw so the UI can surface them.
    ///
    /// First-launch auto-populate: if the user has never touched the
    /// configuration AND the fetched list is non-empty, every published
    /// relayer is auto-added to `endpoints`, the strategy is set to
    /// `.random`, and `hasUserInteracted` flips to `true`. The flag is
    /// sticky — subsequent fetches never re-auto-populate, so a user
    /// who explicitly clears the list isn't fought by the next refresh.
    func refresh() async throws {
        let list = try await fetcher.fetchLatest()
        store.saveCachedKnownList(list)

        let current = cached.configuration
        let updatedConfig: RelayerConfiguration
        if !current.hasUserInteracted && !list.isEmpty {
            updatedConfig = RelayerConfiguration(
                endpoints: list,
                primaryURL: nil,
                strategy: .random,
                hasUserInteracted: true
            )
            store.saveConfiguration(updatedConfig)
        } else {
            updatedConfig = current
        }

        cached = RelayerState(configuration: updatedConfig, knownList: list)
        publish()
    }

    // MARK: - Configuration mutations

    /// Add an endpoint to the configured list. Idempotent on URL — a
    /// second add of the same URL replaces the existing entry's
    /// metadata (name / network) but doesn't duplicate the row.
    /// Returns true on insert, false on update.
    @discardableResult
    func addEndpoint(_ endpoint: RelayerEndpoint) -> Bool {
        var endpoints = cached.configuration.endpoints
        let inserted: Bool
        if let index = endpoints.firstIndex(where: { $0.url == endpoint.url }) {
            endpoints[index] = endpoint
            inserted = false
        } else {
            endpoints.append(endpoint)
            inserted = true
        }
        applyConfiguration(
            RelayerConfiguration(
                endpoints: endpoints,
                primaryURL: cached.configuration.primaryURL,
                strategy: cached.configuration.strategy
            )
        )
        return inserted
    }

    /// Remove the endpoint with the given URL. If the removed endpoint
    /// was the primary, the primary marker clears (next `selectURL`
    /// under `.primary` strategy falls back to the new first endpoint).
    func removeEndpoint(url: URL) {
        let endpoints = cached.configuration.endpoints.filter { $0.url != url }
        let primaryURL = cached.configuration.primaryURL == url ? nil : cached.configuration.primaryURL
        applyConfiguration(
            RelayerConfiguration(
                endpoints: endpoints,
                primaryURL: primaryURL,
                strategy: cached.configuration.strategy
            )
        )
    }

    /// Mark `url` as primary. Pass `nil` to clear the primary marker.
    /// No-op if `url` isn't in the configured endpoints (caller should
    /// have added it first).
    func setPrimary(url: URL?) {
        if let url, !cached.configuration.endpoints.contains(where: { $0.url == url }) {
            return
        }
        applyConfiguration(
            RelayerConfiguration(
                endpoints: cached.configuration.endpoints,
                primaryURL: url,
                strategy: cached.configuration.strategy
            )
        )
    }

    func setStrategy(_ strategy: RelayerStrategy) {
        applyConfiguration(
            RelayerConfiguration(
                endpoints: cached.configuration.endpoints,
                primaryURL: cached.configuration.primaryURL,
                strategy: strategy
            )
        )
    }

    /// Convenience for tests / screens that want to drop everything.
    func clearConfiguration() {
        applyConfiguration(.empty)
    }

    // MARK: - Read

    func currentState() -> RelayerState { cached }

    /// Resolve the URL chain interactors should POST to, per the
    /// configured strategy. Pure read of `cached.configuration`;
    /// no I/O. Returns nil only when the configured-endpoints list
    /// is empty (regardless of strategy).
    func selectURL() -> URL? {
        cached.configuration.selectURL()
    }

    // MARK: - AsyncStream

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

    private func applyConfiguration(_ configuration: RelayerConfiguration) {
        store.saveConfiguration(configuration)
        cached = RelayerState(configuration: configuration, knownList: cached.knownList)
        publish()
    }

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

    private func refreshFromNetwork() async {
        do {
            try await refresh()
        } catch {
            // Cached list (if any) remains valid; nothing to do.
        }
    }
}
