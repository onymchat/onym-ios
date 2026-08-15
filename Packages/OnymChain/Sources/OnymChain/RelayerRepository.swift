import Foundation

/// Outcome of the most recent attempt to fetch the published
/// relayers list. Lets the picker show the right copy:
/// - `.idle`: never attempted (cold launch before `start()`).
/// - `.fetching`: in flight — show the spinner.
/// - `.success`: got an answer (possibly an empty list — UI shows
///   "No published relayers yet" rather than spinning forever).
/// - `.failed(message)`: GitHub unreachable, asset 404, JSON broken,
///   etc. UI shows the message + a retry affordance instead of
///   spinning indefinitely.
public enum RelayerFetchStatus: Equatable, Sendable {
    case idle
    case fetching
    case success
    case failed(message: String)
}

/// Combined snapshot consumed by the picker view. The three halves
/// change independently — the configuration is mutated synchronously
/// by user intents, the known list is the result of an async GitHub
/// fetch, the fetch status reflects the in-flight / failed state of
/// that fetch — but views always want them in one go.
public struct RelayerState: Equatable, Sendable {
    public let configuration: RelayerConfiguration
    public let knownList: [RelayerEndpoint]
    public let fetchStatus: RelayerFetchStatus

    public static let empty = RelayerState(
        configuration: .empty,
        knownList: [],
        fetchStatus: .idle
    )
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
public actor RelayerRepository {
    private let fetcher: any KnownRelayersFetcher
    private let store: any RelayerSelectionStore
    /// Seam over the first-launch auto-populate: consulted right
    /// before a fetch would install the whole published list into an
    /// untouched configuration. Returning `false` defers it — the
    /// fetched list still lands in `knownList` (and the on-disk
    /// cache), but the configuration and `hasUserInteracted` stay
    /// untouched, so a later fetch (or an explicit user pick, e.g.
    /// during onboarding) can still populate. Defaults to always-on,
    /// preserving the historical behavior.
    private let autoPopulatePolicy: @Sendable () -> Bool

    private var cached: RelayerState
    private var continuations: [UUID: AsyncStream<RelayerState>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    public init(
        fetcher: any KnownRelayersFetcher,
        store: any RelayerSelectionStore,
        autoPopulatePolicy: @escaping @Sendable () -> Bool = { true }
    ) {
        self.fetcher = fetcher
        self.store = store
        self.autoPopulatePolicy = autoPopulatePolicy
        self.cached = RelayerState(
            configuration: store.loadConfiguration(),
            knownList: store.loadCachedKnownList(),
            fetchStatus: .idle
        )
    }

    // MARK: - Background refresh

    /// Trigger a background refresh of the known-relayers list.
    /// Idempotent — a second call while the first is in flight is a
    /// no-op. Failures fall through silently; the cached list (if any)
    /// remains the source of truth.
    public func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.refreshFromNetwork()
            // Released on completion so a *failed* bootstrap can be
            // retried. Holding it forever meant one unlucky launch —
            // no connectivity in the first seconds, or a slow fetch —
            // left the device with zero relayer endpoints for the whole
            // session, and every chain read failing with
            // `noActiveRelayer`. The guard still collapses concurrent
            // calls, which is all it was for.
            await self?.clearStartTask()
        }
    }

    private func clearStartTask() {
        startTask = nil
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
    /// `autoPopulatePolicy` gates the install: when it returns `false`
    /// the fetched list only lands in `knownList` (configuration and
    /// flag untouched), leaving the choice to a later fetch or an
    /// explicit user pick.
    public func refresh() async throws {
        // Mark in-flight so the picker stops showing whatever stale
        // status it had and renders the spinner.
        cached = RelayerState(
            configuration: cached.configuration,
            knownList: cached.knownList,
            fetchStatus: .fetching
        )
        publish()

        let list: [RelayerEndpoint]
        do {
            list = try await fetcher.fetchLatest()
        } catch {
            cached = RelayerState(
                configuration: cached.configuration,
                knownList: cached.knownList,
                fetchStatus: .failed(message: Self.message(for: error))
            )
            publish()
            throw error
        }

        store.saveCachedKnownList(list)

        let current = cached.configuration
        let updatedConfig: RelayerConfiguration
        if !current.hasUserInteracted && !list.isEmpty && autoPopulatePolicy() {
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

        cached = RelayerState(
            configuration: updatedConfig,
            knownList: list,
            fetchStatus: .success
        )
        publish()
    }

    /// Map any thrown fetch error to a user-facing one-liner. Keeps
    /// the picker copy short — the chain layer's diagnostic detail
    /// doesn't belong in the UI.
    private static func message(for error: Error) -> String {
        switch error {
        case KnownRelayersFetchError.badStatus(let code):
            return String(localized: "Couldn't reach the published list (status \(code)).")
        case KnownRelayersFetchError.malformedDocument:
            return String(localized: "Published list is in an unexpected format.")
        case is URLError:
            return String(localized: "Couldn't reach the published list.")
        default:
            return String(localized: "Couldn't reach the published list.")
        }
    }

    // MARK: - Configuration mutations

    /// Add an endpoint to the configured list. Idempotent on URL — a
    /// second add of the same URL replaces the existing entry's
    /// metadata (name / network) but doesn't duplicate the row.
    /// Returns true on insert, false on update.
    @discardableResult
    public func addEndpoint(_ endpoint: RelayerEndpoint) -> Bool {
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
    public func removeEndpoint(url: URL) {
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
    public func setPrimary(url: URL?) {
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

    public func setStrategy(_ strategy: RelayerStrategy) {
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

    public func currentState() -> RelayerState { cached }

    /// Resolve the URL chain interactors should POST to, per the
    /// configured strategy. Pure read of `cached.configuration`;
    /// no I/O. Returns nil only when the configured-endpoints list
    /// is empty (regardless of strategy).
    public func selectURL() -> URL? {
        cached.configuration.selectURL()
    }

    // MARK: - AsyncStream

    public nonisolated var snapshots: AsyncStream<RelayerState> {
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
        cached = RelayerState(
            configuration: configuration,
            knownList: cached.knownList,
            fetchStatus: cached.fetchStatus
        )
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
