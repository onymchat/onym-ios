import Foundation
import Observation
import OnymDiscovery
import OnymFoundation

/// Catalog-section state shared by the transport Settings flows
/// (relayer / Nostr / Blossom): the discovery-sourced entries for one
/// seat plus the memoized per-component consent lookups. Extracted
/// because the plumbing was previously copied verbatim into each flow.
///
/// Lifecycle mirrors the flows': `start()` drains the picker's entries
/// stream (so the section populates when the boot-time discovery
/// refresh lands while the screen is open), `refresh()` re-reads the
/// aggregate once (consent-sheet dismiss — a fresh consent changes row
/// badges without a catalog change to push through the stream), and
/// `stop()` cancels the drain so continuations don't accumulate
/// across visits.
///
/// All lookups are memoized once per catalog install — `activeConsent`
/// decodes the whole consent store and the offer a pinned manifest,
/// far too heavy per row per render.
@MainActor
@Observable
public final class DiscoveryCatalogState {
    /// Entries for the "From catalog" section. Empty when the app runs
    /// without discovery.
    public private(set) var entries: [AttributedCatalogEntry] = []
    /// Endpoint URLs of the CONSENTED catalog entries, derived from
    /// the pinned consent records' exact manifest bytes. Used by flows
    /// that also render a published list to hide catalog-sourced rows
    /// from it (they render in the catalog section with attribution
    /// and consent state instead). Derived from `entries`, not any
    /// fetch-time registry, so it can never race a known list rendered
    /// from cache before a fetch completes.
    public private(set) var consentedEndpointURLs: Set<URL> = []

    private var consentRecords: [String: PinnedConsentRecord] = [:]
    private var consentedOffers: [String: ServiceOffer] = [:]
    private let discovery: DiscoveryModulePicker?
    private var task: Task<Void, Never>?

    /// `nil` discovery keeps the state permanently empty — the seam
    /// the flows already expose for running without discovery.
    public init(discovery: DiscoveryModulePicker?) {
        self.discovery = discovery
    }

    /// Begin draining the picker's entries stream. Idempotent.
    public func start() {
        guard task == nil, let discovery else { return }
        task = Task { [weak self] in
            for await entries in discovery.entriesStream() {
                self?.apply(entries)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Re-read the discovery aggregate once.
    public func refresh() {
        guard let discovery else { return }
        Task { [weak self] in
            let entries = await discovery.entries()
            self?.apply(entries)
        }
    }

    /// The active pinned consent for a catalog entry's component
    /// (memoized per catalog install).
    public func activeConsent(for entry: AttributedCatalogEntry) -> PinnedConsentRecord? {
        consentRecords[entry.entry.componentId]
    }

    /// The offer accepted at consent time, resolved from the pinned
    /// manifest snapshot (memoized per catalog install).
    public func consentedOffer(for entry: AttributedCatalogEntry) -> ServiceOffer? {
        consentedOffers[entry.entry.componentId]
    }

    /// Install a catalog aggregate, memoizing the per-component
    /// consent lookups so rendering a row is a dictionary hit instead
    /// of a full consent-store decode.
    private func apply(_ entries: [AttributedCatalogEntry]) {
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
        self.entries = entries
        consentRecords = records
        consentedOffers = offers
        consentedEndpointURLs = consentedURLs
    }
}
