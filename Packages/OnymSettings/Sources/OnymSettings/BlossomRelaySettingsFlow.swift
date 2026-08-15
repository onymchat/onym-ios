import Foundation
import Observation
import OnymTransportBlossom
import OnymDiscovery
import OnymFoundation

/// `@Observable @MainActor` view-model for the Blossom-servers Settings
/// screen. Drains `BlossomServersRepository` snapshots into local
/// `state.snapshot`; intents dispatch to the repository for
/// configuration mutations. Mirrors `NostrRelaySettingsFlow`.
///
/// Blossom servers speak HTTPS (`https://` / `http://` for local dev),
/// so validation + placeholder copy differ from the `wss://` Nostr
/// flow; there's no primary/strategy concept (uploads target the first
/// configured server).
@MainActor
@Observable
public final class BlossomRelaySettingsFlow {
    /// Combined snapshot from the repository plus the custom-URL draft
    /// the user is currently typing. Draft is local-only until Add.
    public struct State: Equatable {
        public var snapshot: BlossomServersConfiguration
        public var customDraft: String
        public var customDraftError: String?
    }

    public private(set) var state: State
    /// Discovery-sourced "blob.storage" entries for the "From catalog"
    /// section. Empty when the app runs without discovery.
    public private(set) var catalogEntries: [AttributedCatalogEntry] = []
    /// Consent state per componentId, memoized once per catalog
    /// refresh — `activeConsent` decodes the whole consent store and
    /// the offer a pinned manifest, far too heavy per row per render.
    private var consentRecords: [String: PinnedConsentRecord] = [:]
    private var consentedOffers: [String: ServiceOffer] = [:]

    private let repository: BlossomServersRepository
    /// Optional discovery seam — nil keeps this screen exactly as it
    /// was before discovery existed.
    let discovery: DiscoveryModulePicker?
    private var snapshotTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?

    public init(repository: BlossomServersRepository, discovery: DiscoveryModulePicker? = nil) {
        self.repository = repository
        self.discovery = discovery
        self.state = State(snapshot: .empty, customDraft: "", customDraftError: nil)
    }

    /// Begin draining repository snapshots AND discovery catalog
    /// updates. Idempotent. The catalog is a stream, not a one-shot
    /// read, so the "From catalog" section populates when the
    /// boot-time discovery refresh lands while this screen is open.
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

    /// Install a catalog aggregate, memoizing the per-component
    /// consent lookups so rendering a row is a dictionary hit instead
    /// of a full consent-store decode.
    private func applyCatalog(_ entries: [AttributedCatalogEntry]) {
        guard let discovery else { return }
        var records: [String: PinnedConsentRecord] = [:]
        var offers: [String: ServiceOffer] = [:]
        for componentId in Set(entries.map(\.entry.componentId)) {
            guard let record = discovery.activeConsent(componentId) else { continue }
            records[componentId] = record
            if let offerId = record.offerId {
                offers[componentId] = record.consentedManifest()?
                    .offers.first { $0.offerId == offerId }
            }
        }
        catalogEntries = entries
        consentRecords = records
        consentedOffers = offers
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

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        catalogTask?.cancel()
        catalogTask = nil
    }

    // MARK: - Intents

    public func customDraftChanged(_ text: String) {
        state.customDraft = text
        state.customDraftError = nil
    }

    /// Tap the Add button next to the custom-URL field. Validates
    /// `https://` / `http://` scheme + non-empty host.
    public func tappedAddCustom() {
        let trimmed = state.customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validate(trimmed) else {
            state.customDraftError = String(localized: "Enter a valid https:// URL")
            return
        }
        let endpoint = BlossomServerEndpoint.custom(url: url)
        state.customDraft = ""
        Task { await repository.addEndpoint(endpoint) }
    }

    /// Swipe-to-delete on a configured row.
    func tappedRemove(url: URL) {
        Task { await repository.removeEndpoint(url: url) }
    }

    /// Restore default — re-installs the Onym Official seed and clears
    /// the user-interaction flag so the seed sticks across relaunches.
    func tappedResetToDefault() {
        Task { await repository.resetToDefault() }
    }

    // MARK: - Private

    /// Permissive HTTP(S) URL validation: must parse, must have `https`
    /// or `http` scheme (the latter for local dev / loopback), must
    /// have a non-empty host.
    public static func validate(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
