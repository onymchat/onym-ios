import Foundation
import OnymChain
import OnymDiscovery
import OnymFoundation

/// Stateless interactor backing the relayer Settings screen. Drains
/// `RelayerRepository` snapshots into local `state.snapshot`; intents
/// dispatch to the repository for configuration mutations. The view
/// reads from `state` and calls the intent methods on tap; navigation
/// itself is owned by SwiftUI.
@MainActor
@Observable
public final class RelayerSettingsFlow {
    /// Combined snapshot from the repository plus the custom-URL
    /// draft the user is currently typing. The draft is local-only
    /// until they tap Add — the repository never sees half-typed URLs.
    public struct State: Equatable {
        public var snapshot: RelayerState
        public var customDraft: String
        public var customDraftError: String?
    }

    public private(set) var state: State
    /// Discovery-sourced "notary" entries for the "From catalog"
    /// section. Empty when the app runs without discovery.
    public private(set) var catalogEntries: [AttributedCatalogEntry] = []
    /// Consent state per componentId, memoized once per catalog
    /// refresh — `activeConsent` decodes the whole consent store and
    /// the offer a pinned manifest, far too heavy per row per render.
    private var consentRecords: [String: PinnedConsentRecord] = [:]
    private var consentedOffers: [String: ServiceOffer] = [:]
    /// Endpoint URLs of the CONSENTED catalog entries, derived from
    /// the pinned consent records' exact manifest bytes. Those rows
    /// are hidden from the tap-to-add published list — a catalog
    /// entry renders in the "From catalog" section with attribution
    /// and consent state instead. Derived from `catalogEntries`, not
    /// from any fetch-time registry, so it can never race the known
    /// list rendering from cache before a fetch completes.
    private var discoverySourcedKnownURLs: Set<URL> = []

    private let repository: RelayerRepository
    /// Optional discovery seam — nil keeps this screen exactly as it
    /// was before discovery existed.
    let discovery: DiscoveryModulePicker?
    private var snapshotTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?

    public init(repository: RelayerRepository, discovery: DiscoveryModulePicker? = nil) {
        self.repository = repository
        self.discovery = discovery
        self.state = State(snapshot: .empty, customDraft: "", customDraftError: nil)
    }

    /// Begin draining repository snapshots AND discovery catalog
    /// updates. Idempotent — safe to call from `.task` on every
    /// appear. The catalog is a stream, not a one-shot read, so the
    /// "From catalog" section populates when the boot-time discovery
    /// refresh lands while this screen is already open.
    public func start() {
        if snapshotTask == nil {
            snapshotTask = Task { [weak self] in
                guard let self else { return }
                for await snapshot in self.repository.snapshots {
                    self.state.snapshot = snapshot
                }
            }
        }
        if catalogTask == nil, let discovery {
            catalogTask = Task { [weak self] in
                for await entries in discovery.entriesStream() {
                    self?.applyCatalog(entries)
                }
            }
        }
    }

    /// Re-read the discovery aggregate once (consent-sheet dismiss — a
    /// fresh consent changes the rows' badges without any catalog
    /// change to push through the stream).
    public func refreshCatalog() {
        guard let discovery else { return }
        Task { [weak self] in
            let entries = await discovery.entries()
            self?.applyCatalog(entries)
        }
    }

    /// Install a catalog aggregate: memoize the per-component consent
    /// lookups (so rendering a row is a dictionary hit instead of a
    /// full consent-store decode) and rebuild the published-list
    /// dedupe set from the consented manifests' endpoint URLs.
    private func applyCatalog(_ entries: [AttributedCatalogEntry]) {
        guard let discovery else { return }
        var records: [String: PinnedConsentRecord] = [:]
        var offers: [String: ServiceOffer] = [:]
        var consentedURLs: Set<URL> = []
        for componentId in Set(entries.map(\.entry.componentId)) {
            guard let record = discovery.activeConsent(componentId) else { continue }
            records[componentId] = record
            consentedURLs.formUnion(record.consentedEndpointURLs())
            if let offerId = record.offerId {
                offers[componentId] = record.consentedManifest()?
                    .offers.first { $0.offerId == offerId }
            }
        }
        catalogEntries = entries
        consentRecords = records
        consentedOffers = offers
        discoverySourcedKnownURLs = consentedURLs
    }

    /// The active pinned consent for a catalog entry's component, when
    /// discovery is wired (memoized per catalog refresh).
    public func activeConsent(for entry: AttributedCatalogEntry) -> PinnedConsentRecord? {
        consentRecords[entry.entry.componentId]
    }

    /// The offer accepted at consent time, resolved from the pinned
    /// manifest snapshot (memoized per catalog refresh).
    public func consentedOffer(for entry: AttributedCatalogEntry) -> ServiceOffer? {
        consentedOffers[entry.entry.componentId]
    }

    public func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        catalogTask?.cancel()
        catalogTask = nil
    }

    // MARK: - Intents

    /// User tapped a row in the published-list section to add it to
    /// the configured list.
    public func tappedAddKnown(_ endpoint: RelayerEndpoint) {
        Task { await repository.addEndpoint(endpoint) }
    }

    public func customDraftChanged(_ text: String) {
        state.customDraft = text
        state.customDraftError = nil
    }

    /// User tapped the Add button next to the custom-URL field.
    public func tappedAddCustom() {
        let trimmed = state.customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validate(trimmed) else {
            state.customDraftError = String(localized: "Enter a valid https:// URL")
            return
        }
        let endpoint = RelayerEndpoint.custom(url: url)
        state.customDraft = ""
        Task { await repository.addEndpoint(endpoint) }
    }

    /// Swipe-to-delete on a configured row.
    public func tappedRemove(url: URL) {
        Task { await repository.removeEndpoint(url: url) }
    }

    /// Tap the star on a configured row to mark it primary.
    public func tappedSetPrimary(url: URL) {
        Task { await repository.setPrimary(url: url) }
    }

    /// Strategy segmented control change.
    public func tappedStrategy(_ strategy: RelayerStrategy) {
        Task { await repository.setStrategy(strategy) }
    }

    /// Retry button on a `.failed` fetch state. Kicks off another
    /// fetch; the repository sets `.fetching` immediately and the
    /// view re-renders accordingly.
    func tappedRetryFetch() {
        Task { try? await repository.refresh() }
    }

    // MARK: - Read helpers

    /// Configured endpoints that aren't already in the user's list —
    /// drives the "Add from published list" section. Hides published
    /// entries the user has already added so adding a duplicate
    /// doesn't ghost as a no-op, AND consented catalog entries'
    /// endpoints (the only discovery-derived URLs the known-list
    /// fetcher can serve — its consent gate excludes the rest): those
    /// render in the "From catalog" section with attribution + consent
    /// state, and a bare duplicate row here would obscure that.
    public var unconfiguredKnownList: [RelayerEndpoint] {
        let configuredURLs = Set(state.snapshot.configuration.endpoints.map { $0.url })
        return state.snapshot.knownList.filter {
            !configuredURLs.contains($0.url) && !discoverySourcedKnownURLs.contains($0.url)
        }
    }

    public func isPrimary(_ endpoint: RelayerEndpoint) -> Bool {
        state.snapshot.configuration.primaryURL == endpoint.url
    }

    // MARK: - Private

    /// Permissive URL validation: must parse, must have an http or
    /// https scheme, must have a host. Same rules as the previous
    /// single-selection picker (PR #18).
    public static func validate(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
