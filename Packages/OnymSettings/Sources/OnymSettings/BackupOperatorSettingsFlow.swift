import Foundation
import Observation
import OnymDiscovery
import OnymFoundation

/// `@Observable @MainActor` view-model for Settings → Backup
/// Operators: the discovery catalog's `storage.backup` entries, and
/// nothing else.
///
/// Thinner than the transport flows on purpose. `RelayerSettingsFlow`
/// and friends pair the catalog section with a configured list they
/// can add to, remove from and reorder, because their repository is
/// the operational source of truth for the seat. The backup seat's
/// source of truth is the pinned consent record itself — read straight
/// out of the consent store by `BackupSeat.consentedManifests` — so
/// there is no configuration for this screen to edit and no custom-URL
/// field to offer: an operator is adopted by consenting to its signed
/// manifest and dropped by withdrawing that consent, which is the
/// Device Backup screen's "Stop backing up".
///
/// What is left is the catalog plumbing, and that is shared with the
/// other pickers (`DiscoveryCatalogState`) rather than copied: the
/// entries stream, so the section populates when the boot-time
/// discovery refresh lands while the screen is open, and the memoized
/// per-component consent lookups, so a row costs a dictionary hit
/// instead of a full consent-store decode per render.
@MainActor
@Observable
public final class BackupOperatorSettingsFlow {
    /// Catalog-section state (entries + memoized consent lookups),
    /// shared plumbing with the relayer/Nostr/Blossom flows.
    private let catalog: DiscoveryCatalogState

    /// Discovery-sourced `storage.backup` entries. Empty when the app
    /// runs without discovery, or when no provider this person trusts
    /// lists a backup operator — the screen says so rather than
    /// pretending to be loading forever.
    public var catalogEntries: [AttributedCatalogEntry] { catalog.entries }

    /// Optional discovery seam, `nil` in builds without the discovery
    /// stack (the UI-test harness) — the same seam the transport flows
    /// expose, and the reason this screen degrades to an explanation
    /// instead of a blank list.
    let discovery: DiscoveryModulePicker?

    public init(discovery: DiscoveryModulePicker?) {
        self.discovery = discovery
        self.catalog = DiscoveryCatalogState(discovery: discovery)
    }

    /// Begin draining discovery catalog updates. Idempotent.
    public func start() {
        catalog.start()
    }

    /// Paired with `start()`: the drain retains the flow and the stream
    /// never finishes on its own, so without this the continuation
    /// would accumulate on every visit.
    public func stop() {
        catalog.stop()
    }

    /// Re-read the discovery aggregate once (consent-sheet dismiss — a
    /// fresh consent changes a row's badge with no catalog change to
    /// push through the stream).
    public func refreshCatalog() {
        catalog.refresh()
    }

    /// The active pinned consent for a catalog entry's component
    /// (memoized per catalog refresh).
    public func activeConsent(for entry: AttributedCatalogEntry) -> PinnedConsentRecord? {
        catalog.activeConsent(for: entry)
    }

    /// The offer accepted at consent time, resolved from the pinned
    /// manifest snapshot (memoized per catalog refresh).
    public func consentedOffer(for entry: AttributedCatalogEntry) -> ServiceOffer? {
        catalog.consentedOffer(for: entry)
    }
}
