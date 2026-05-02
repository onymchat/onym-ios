import Foundation

/// Snapshot the picker view subscribes to. Combines the cached
/// manifest with the user's selections — the picker reads both.
///
/// The resolution rules (binding / available-releases / anchored
/// network membership) live on this value type so SwiftUI render
/// paths can call them synchronously without round-tripping the
/// repository actor on every cell.
struct ContractsState: Equatable, Sendable {
    let manifest: ContractsManifest
    let selections: [AnchorSelectionKey: String]

    static let empty = ContractsState(manifest: .empty, selections: [:])

    /// Resolve `key` to a concrete `AnchorBinding` per:
    /// 1. Explicit selection wins.
    /// 2. Default to latest release with an entry for this key.
    /// 3. Otherwise nil ("no contracts yet").
    func binding(for key: AnchorSelectionKey) -> AnchorBinding? {
        if let selectedTag = selections[key],
           let release = manifest.releases.first(where: { $0.release == selectedTag }),
           let entry = release.contracts.first(where: { $0.network == key.network && $0.type == key.type })
        {
            return AnchorBinding(
                network: entry.network,
                governanceType: entry.type,
                contractID: entry.id,
                release: release.release
            )
        }
        for release in manifest.releases {
            if let entry = release.contracts.first(where: { $0.network == key.network && $0.type == key.type }) {
                return AnchorBinding(
                    network: entry.network,
                    governanceType: entry.type,
                    contractID: entry.id,
                    release: release.release
                )
            }
        }
        return nil
    }

    /// Releases that have a contract for `key`, in the manifest's
    /// newest-first order.
    func availableReleases(for key: AnchorSelectionKey) -> [ContractRelease] {
        manifest.releases.filter { release in
            release.contracts.contains { $0.network == key.network && $0.type == key.type }
        }
    }

    /// True when at least one release has at least one contract on
    /// `network`. Used to gray out the Mainnet row until contracts
    /// ship there.
    func hasAnyContracts(network: ContractNetwork) -> Bool {
        manifest.releases.contains { release in
            release.contracts.contains { $0.network == network }
        }
    }
}

/// Owns the contracts manifest + the user's per-(network, type)
/// selections + the resolution rules that turn a selection key into
/// a concrete `AnchorBinding`. Mirrors `RelayerRepository` shape.
///
/// **Resolution rules** (load-bearing — repeated in the README and
/// the cross-platform Android prompt so iOS / Android stay aligned):
///
/// 1. If the user has an explicit selection for `key` AND the
///    manifest has a release with that tag AND that release has a
///    contract for this `(network, type)` → use it.
/// 2. Otherwise default to the **latest** release that has a
///    contract for `(network, type)` (manifest is sorted newest-first).
/// 3. Otherwise return nil — the UI shows "No contracts yet" and
///    chain interactors get back `nil` from `binding(for:)`.
actor ContractsRepository {
    private let fetcher: any ContractsManifestFetcher
    private let store: any AnchorSelectionStore

    private var cached: ContractsState
    private var continuations: [UUID: AsyncStream<ContractsState>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    init(fetcher: any ContractsManifestFetcher, store: any AnchorSelectionStore) {
        self.fetcher = fetcher
        self.store = store
        self.cached = ContractsState(
            manifest: store.loadCachedManifest() ?? .empty,
            selections: store.loadSelections()
        )
    }

    /// Trigger a background fetch of the latest manifest. Idempotent.
    /// Failures fall through silently — the cached manifest (if any)
    /// remains the source of truth.
    func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.refreshSilently()
        }
    }

    /// Force a refresh and surface any error to the caller (so a
    /// future pull-to-refresh UI can show progress / error state).
    func refresh() async throws {
        var manifest = try await fetcher.fetchLatest()
        manifest = Self.sortedNewestFirst(manifest)
        store.saveCachedManifest(manifest)
        cached = ContractsState(manifest: manifest, selections: cached.selections)
        publish()
    }

    // MARK: - Selection mutations

    /// User explicitly picked `releaseTag` for the (network, type)
    /// in `key`. Subsequent `binding(for: key)` calls return that
    /// release's contract.
    func select(key: AnchorSelectionKey, releaseTag: String) {
        var selections = cached.selections
        selections[key] = releaseTag
        store.saveSelections(selections)
        cached = ContractsState(manifest: cached.manifest, selections: selections)
        publish()
    }

    /// Drop the explicit selection for `key`. After this,
    /// `binding(for: key)` falls back to the default-to-latest rule.
    func clearSelection(key: AnchorSelectionKey) {
        var selections = cached.selections
        selections.removeValue(forKey: key)
        store.saveSelections(selections)
        cached = ContractsState(manifest: cached.manifest, selections: selections)
        publish()
    }

    // MARK: - Read

    func currentState() -> ContractsState { cached }

    /// Convenience: resolve `key` to a concrete `AnchorBinding` per
    /// the rules on `ContractsState`. Async because it crosses the
    /// actor; SwiftUI render paths should hold a `ContractsState`
    /// snapshot directly and call `state.binding(for:)` synchronously.
    func binding(for key: AnchorSelectionKey) -> AnchorBinding? {
        cached.binding(for: key)
    }

    /// Convenience: see `ContractsState.availableReleases(for:)`.
    func availableReleases(for key: AnchorSelectionKey) -> [ContractRelease] {
        cached.availableReleases(for: key)
    }

    // MARK: - AsyncStream

    nonisolated var snapshots: AsyncStream<ContractsState> {
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
        continuation: AsyncStream<ContractsState>.Continuation
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

    private func refreshSilently() async {
        do {
            try await refresh()
        } catch {
            // Cached manifest (if any) remains valid; nothing to do.
        }
    }

    /// Manifest's `releases[]` is sorted newest-first so default-to-
    /// latest is just `releases.first { has-entry-for-key }`. The
    /// upstream JSON should already be sorted, but defensive sort here
    /// removes a load-bearing wire-format invariant.
    private static func sortedNewestFirst(_ manifest: ContractsManifest) -> ContractsManifest {
        let sorted = manifest.releases.sorted { $0.publishedAt > $1.publishedAt }
        return ContractsManifest(version: manifest.version, releases: sorted)
    }
}
