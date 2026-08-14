import Foundation

/// Outcome of the most recent refresh across all enabled sources.
/// Same shape as `RelayerFetchStatus` so the eventual settings UI can
/// reuse its spinner / retry copy.
public enum DiscoveryFetchStatus: Equatable, Sendable {
    case idle
    case fetching
    case success
    case failed(message: String)
}

/// Where an aggregated entry came from. Kept alongside every entry so
/// the UI can disclose the provider, catalog, and the provider's
/// declared relationship / placement for that entry (spec §7 — every
/// source's copy stays visible; there is no cross-source dedup).
public struct SourceAttribution: Equatable, Hashable, Sendable {
    public let providerId: String
    public let sourceLabel: String
    public let catalogId: String
    /// `sha256:<hex>` of the accepted snapshot the entry came from.
    public let snapshotDigest: String
    public let relationship: String
    public let placement: String

    public init(
        providerId: String,
        sourceLabel: String,
        catalogId: String,
        snapshotDigest: String,
        relationship: String,
        placement: String
    ) {
        self.providerId = providerId
        self.sourceLabel = sourceLabel
        self.catalogId = catalogId
        self.snapshotDigest = snapshotDigest
        self.relationship = relationship
        self.placement = placement
    }
}

/// One catalog entry plus its provenance.
public struct AttributedCatalogEntry: Equatable, Sendable, Identifiable {
    public let entry: CatalogEntry
    public let source: SourceAttribution

    /// Stable id for list diffing: the same component listed by two
    /// sources (or two catalogs) is two visible rows.
    public var id: String {
        source.providerId + "|" + source.catalogId + "|" + entry.componentId
    }

    public init(entry: CatalogEntry, source: SourceAttribution) {
        self.entry = entry
        self.source = source
    }
}

/// Per-source status for the settings UI: the source itself plus the
/// last refresh's trust / fetch error, if any (equivocation and
/// rollback surface here as `snapshotInvalid` reasons).
public struct DiscoverySourceStatus: Equatable, Sendable, Identifiable {
    public let source: DiscoverySource
    public let lastError: String?

    public var id: String { source.providerId }

    public init(source: DiscoverySource, lastError: String?) {
        self.source = source
        self.lastError = lastError
    }
}

/// Combined snapshot consumed by views: the configured sources (with
/// per-source error state), the verified aggregate across all enabled
/// sources, and the refresh status.
public struct DiscoveryState: Equatable, Sendable {
    public let sources: [DiscoverySourceStatus]
    public let aggregate: [AttributedCatalogEntry]
    public let fetchStatus: DiscoveryFetchStatus

    public static let empty = DiscoveryState(sources: [], aggregate: [], fetchStatus: .idle)

    public init(
        sources: [DiscoverySourceStatus],
        aggregate: [AttributedCatalogEntry],
        fetchStatus: DiscoveryFetchStatus
    ) {
        self.sources = sources
        self.aggregate = aggregate
        self.fetchStatus = fetchStatus
    }
}

/// Preview returned by `addSource(manifestURL:)`: the manifest is
/// fetched and fully verified (TOFU — its own operator key), but
/// **nothing is pinned or persisted** until the user confirms the key
/// fingerprint out-of-band and the caller passes the preview back to
/// `confirmAddSource`.
public struct DiscoveryProviderPreview: Sendable {
    public let manifestURL: URL
    public let signed: SignedProviderManifest

    public var providerId: String { signed.manifest.providerId }
    /// Fingerprint of the key that will be pinned on confirm.
    public var operatorKeyFingerprint: String {
        DiscoverySource.fingerprint(ofKeyHex: signed.operatorPublicKeyHex)
    }
}

/// Owns the user's discovery sources + the verified catalog aggregate.
/// Mirrors `RelayerRepository`'s shape: `actor` with snapshot replay
/// on subscribe and a fresh push after every mutation / refresh.
///
/// Trust is hard-enforced: a source whose manifest or snapshot fails
/// any `DiscoveryTrust` check contributes nothing to the aggregate and
/// surfaces the failure on its `DiscoverySourceStatus`; previously
/// retained snapshots of *other* catalogs and sources are unaffected.
public actor DiscoveryRepository {
    private let fetcher: any DiscoveryFetching
    private let store: any DiscoveryStore
    private let now: @Sendable () -> Date

    private var configuration: DiscoverySourcesConfiguration
    private var lastErrors: [String: String] = [:]
    private var aggregate: [AttributedCatalogEntry] = []
    private var fetchStatus: DiscoveryFetchStatus = .idle
    private var continuations: [UUID: AsyncStream<DiscoveryState>.Continuation] = [:]
    private var startTask: Task<Void, Never>?

    public init(
        fetcher: any DiscoveryFetching,
        store: any DiscoveryStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.store = store
        self.now = now
        self.configuration = store.loadConfiguration()
    }

    // MARK: - Lifecycle

    /// Seed the default source (first run only, and never a removed
    /// one), rebuild the offline aggregate from retained snapshots,
    /// then refresh in the background. Idempotent while in flight;
    /// released on completion so a failed bootstrap can be retried.
    public func start() {
        seedDefaultIfNeeded()
        rebuildAggregateFromRetained()
        publish()
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.refresh()
            await self?.clearStartTask()
        }
    }

    private func clearStartTask() {
        startTask = nil
    }

    /// Seed-on-empty gating: only before any interaction, and only if
    /// the default was never explicitly removed.
    private func seedDefaultIfNeeded() {
        guard !configuration.hasUserInteracted else { return }
        let defaultSource = DiscoverySource.onymDefault
        guard !configuration.removedDefaultProviderIds.contains(defaultSource.providerId) else { return }
        guard !configuration.sources.contains(where: { $0.providerId == defaultSource.providerId }) else { return }
        applyConfiguration(DiscoverySourcesConfiguration(
            sources: configuration.sources + [defaultSource],
            removedDefaultProviderIds: configuration.removedDefaultProviderIds,
            hasUserInteracted: true
        ))
    }

    // MARK: - Refresh

    /// Refresh every enabled, pinned source. Per-source failures are
    /// tolerated: they surface on that source's status while the other
    /// sources' results (and this source's previously retained
    /// catalogs) stay in the aggregate.
    public func refresh() async {
        fetchStatus = .fetching
        publish()

        var refreshedAnything = false
        var failures = 0

        for source in configuration.sources where source.isEnabled {
            // A source without a pinned key (an unconfirmed seeded
            // default) is skipped: hard enforcement means we never
            // build an aggregate on an unpinned identity.
            guard let pinnedKey = source.pinnedOperatorKeyHex else { continue }
            do {
                try await refreshSource(source, pinnedKey: pinnedKey)
                lastErrors[source.providerId] = nil
                refreshedAnything = true
            } catch {
                lastErrors[source.providerId] = Self.message(for: error)
                failures += 1
            }
        }

        rebuildAggregateFromRetained()
        if failures > 0 && !refreshedAnything {
            fetchStatus = .failed(message: String(localized: "Couldn't refresh any discovery source."))
        } else {
            fetchStatus = .success
        }
        publish()
    }

    private func refreshSource(_ source: DiscoverySource, pinnedKey: String) async throws {
        let manifestBytes = try await fetcher.fetchProviderManifest(url: source.manifestURL)
        let signedManifest = try DiscoveryTrust.verifyProviderManifest(
            raw: manifestBytes,
            pinnedOperatorKeyHex: pinnedKey,
            now: now()
        )
        // Refresh-time identity match (§6): the URL must still serve
        // the pinned provider. `seat` and `implementationProfileId`
        // are already pinned to this profile's constants by
        // `verifyProviderManifest`; `providerId` is the per-source
        // identity that can drift.
        guard signedManifest.manifest.providerId == source.providerId else {
            throw DiscoveryTrustError.providerManifestInvalid(
                reason: "providerId does not match the pinned source (the URL now serves a different provider)"
            )
        }

        var updated = source
        for catalog in signedManifest.manifest.catalogs {
            guard let snapshotURL = catalog.snapshotURL else { continue }
            let snapshotBytes = try await fetcher.fetchSnapshot(url: snapshotURL)
            let previousRaw = store.loadRetainedSnapshot(
                providerId: source.providerId,
                catalogId: catalog.catalogId
            )
            let accepted = try DiscoveryTrust.verifySnapshot(
                raw: snapshotBytes,
                manifest: signedManifest,
                previousRaw: previousRaw,
                now: now()
            )
            store.saveRetainedSnapshot(
                accepted.rawBytes,
                providerId: source.providerId,
                catalogId: catalog.catalogId
            )
            updated = updated.withLastAccepted(
                AcceptedSnapshotRecord(
                    digest: accepted.digest,
                    sequence: accepted.snapshot.sequence,
                    acceptedAt: now()
                ),
                forCatalog: catalog.catalogId
            )
        }

        replaceSource(updated)
    }

    // MARK: - Source management

    /// Fetch + verify a provider manifest at `manifestURL` (TOFU: the
    /// manifest's own operator key). Pins **nothing** — the returned
    /// preview carries the key fingerprint for the user to confirm;
    /// pass it to `confirmAddSource` to persist.
    public func addSource(manifestURL: URL) async throws -> DiscoveryProviderPreview {
        let bytes = try await fetcher.fetchProviderManifest(url: manifestURL)
        let signed = try DiscoveryTrust.verifyProviderManifest(
            raw: bytes,
            pinnedOperatorKeyHex: nil,
            now: now()
        )
        return DiscoveryProviderPreview(manifestURL: manifestURL, signed: signed)
    }

    /// Pin the previewed operator key and persist the source. An
    /// explicit re-add clears the provider from
    /// `removedDefaultProviderIds` — only *silent* restoration is
    /// forbidden.
    @discardableResult
    public func confirmAddSource(
        _ preview: DiscoveryProviderPreview,
        userLabel: String? = nil
    ) -> DiscoverySource {
        let source = DiscoverySource(
            providerId: preview.providerId,
            userLabel: userLabel ?? preview.manifestURL.host() ?? preview.providerId,
            manifestURL: preview.manifestURL,
            pinnedOperatorKeyHex: preview.signed.operatorPublicKeyHex,
            addedAt: now()
        )
        var sources = configuration.sources.filter { $0.providerId != source.providerId }
        sources.append(source)
        applyConfiguration(DiscoverySourcesConfiguration(
            sources: sources,
            removedDefaultProviderIds: configuration.removedDefaultProviderIds
                .subtracting([source.providerId])
        ))
        return source
    }

    /// Remove a source durably: its pin and retained snapshots are
    /// deleted, and its providerId joins `removedDefaultProviderIds`
    /// so no future seeding brings it back.
    public func removeSource(providerId: String) {
        guard let source = configuration.sources.first(where: { $0.providerId == providerId }) else {
            return
        }
        store.removeRetainedSnapshots(
            providerId: providerId,
            catalogIds: Array(source.lastAccepted.keys)
        )
        lastErrors[providerId] = nil
        applyConfiguration(DiscoverySourcesConfiguration(
            sources: configuration.sources.filter { $0.providerId != providerId },
            removedDefaultProviderIds: configuration.removedDefaultProviderIds.union([providerId])
        ))
        rebuildAggregateFromRetained()
        publish()
    }

    public func setEnabled(_ enabled: Bool, providerId: String) {
        guard let source = configuration.sources.first(where: { $0.providerId == providerId }) else {
            return
        }
        replaceSource(source.withEnabled(enabled))
        rebuildAggregateFromRetained()
        publish()
    }

    // MARK: - Read

    public func currentState() -> DiscoveryState {
        DiscoveryState(
            sources: configuration.sources.map {
                DiscoverySourceStatus(source: $0, lastError: lastErrors[$0.providerId])
            },
            aggregate: aggregate,
            fetchStatus: fetchStatus
        )
    }

    /// Local filtering — the profile has no server-side query.
    public func entries(seatType: String) -> [AttributedCatalogEntry] {
        aggregate.filter { $0.entry.seatType == seatType }
    }

    // MARK: - AsyncStream

    public nonisolated var snapshots: AsyncStream<DiscoveryState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    /// Rebuild the aggregate from the retained (already verified)
    /// snapshots of every enabled source, in source order then the
    /// snapshot's policy-rank entry order. Entries from all sources
    /// stay visible — attribution, not dedup.
    private func rebuildAggregateFromRetained() {
        var result: [AttributedCatalogEntry] = []
        for source in configuration.sources where source.isEnabled {
            for (catalogId, record) in source.lastAccepted.sorted(by: { $0.key < $1.key }) {
                guard let raw = store.loadRetainedSnapshot(
                    providerId: source.providerId,
                    catalogId: catalogId
                ) else { continue }
                guard let snapshot = try? DiscoveryJSON.decoder().decode(CatalogSnapshot.self, from: raw) else {
                    continue
                }
                // Entries from an expired retained snapshot are stale
                // history, not current recommendations (§8).
                guard snapshot.expiresAt > now() else { continue }
                for entry in snapshot.entries {
                    result.append(AttributedCatalogEntry(
                        entry: entry,
                        source: SourceAttribution(
                            providerId: source.providerId,
                            sourceLabel: source.userLabel,
                            catalogId: catalogId,
                            snapshotDigest: record.digest,
                            relationship: entry.relationship,
                            placement: entry.placement
                        )
                    ))
                }
            }
        }
        aggregate = result
    }

    private func replaceSource(_ source: DiscoverySource) {
        let sources = configuration.sources.map {
            $0.providerId == source.providerId ? source : $0
        }
        applyConfiguration(DiscoverySourcesConfiguration(
            sources: sources,
            removedDefaultProviderIds: configuration.removedDefaultProviderIds,
            hasUserInteracted: configuration.hasUserInteracted
        ))
    }

    private func applyConfiguration(_ new: DiscoverySourcesConfiguration) {
        store.saveConfiguration(new)
        configuration = new
    }

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<DiscoveryState>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(currentState())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        let state = currentState()
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let DiscoveryTrustError.providerManifestInvalid(reason):
            return String(localized: "Provider manifest rejected: \(reason)")
        case let DiscoveryTrustError.snapshotInvalid(reason):
            return String(localized: "Catalog snapshot rejected: \(reason)")
        case DiscoveryTrustError.snapshotExpired:
            return String(localized: "Catalog snapshot has expired.")
        case DiscoveryFetchError.rateLimited:
            return String(localized: "The provider is rate limiting requests.")
        case DiscoveryFetchError.oversize:
            return String(localized: "The provider served an oversized document.")
        case let DiscoveryFetchError.badStatus(code):
            return String(localized: "Couldn't reach the provider (status \(code)).")
        case is URLError:
            return String(localized: "Couldn't reach the provider.")
        default:
            return String(localized: "Couldn't refresh the provider.")
        }
    }
}
