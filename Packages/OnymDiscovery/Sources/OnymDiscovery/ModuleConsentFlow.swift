import Foundation
import Observation
import OnymFoundation

/// Everything a per-seat picker needs to render its "From catalog"
/// section, bundled so the app's composition root can hand one value
/// to each settings flow. Optional everywhere it's consumed — when the
/// app runs without discovery (UI-test harness), the pickers render
/// exactly as before.
@MainActor
public struct DiscoveryModulePicker {
    /// Verified catalog entries for this picker's seat type (the app
    /// pre-binds the seat).
    public let entries: () async -> [AttributedCatalogEntry]
    /// The active pinned consent for a componentId, if any — drives
    /// the consent-state text on catalog rows.
    public let activeConsent: (_ componentId: String) -> PinnedConsentRecord?
    /// Build the consent flow for one entry. The app pre-binds the
    /// seat-specific `apply` closure that writes the endpoint into the
    /// legacy configuration.
    public let makeConsentFlow: @MainActor (AttributedCatalogEntry) -> ModuleConsentFlow
    /// Live stream of this seat's catalog entries: yields the current
    /// aggregate immediately, then again after every discovery refresh
    /// — so the picker's "From catalog" section populates when the
    /// boot-time refresh lands while the screen is already open. The
    /// default wraps `entries` as a one-shot stream (test seams that
    /// never refresh).
    public let entriesStream: @MainActor () -> AsyncStream<[AttributedCatalogEntry]>

    public init(
        entries: @escaping () async -> [AttributedCatalogEntry],
        activeConsent: @escaping (_ componentId: String) -> PinnedConsentRecord?,
        entriesStream: (@MainActor () -> AsyncStream<[AttributedCatalogEntry]>)? = nil,
        makeConsentFlow: @escaping @MainActor (AttributedCatalogEntry) -> ModuleConsentFlow
    ) {
        self.entries = entries
        self.activeConsent = activeConsent
        self.makeConsentFlow = makeConsentFlow
        self.entriesStream = entriesStream ?? {
            AsyncStream { continuation in
                let task = Task { @MainActor in
                    continuation.yield(await entries())
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

/// Generalized consent flow for non-moderation seats (transport,
/// notary, blob storage): fetch the catalog entry's manifest, verify
/// it against the catalog-pinned digest, put the exact reviewed terms
/// on screen, and on accept pin the consent + record the selection +
/// apply the endpoint to the seat's legacy configuration.
///
/// Modeled on `ModerationConsentFlow` minus the picker and the signing
/// step — consent here is a local pin, not a signed mandate. The
/// moderation seat must never route through this flow
/// (`ModuleConsentAcceptance.excludedSeatType`); moderation entries go
/// to the existing mandate flow.
///
/// Lives in OnymDiscovery (not OnymSettings, which renders it) so its
/// state machine is unit-testable — OnymSettings has no test target.
@MainActor
@Observable
public final class ModuleConsentFlow {
    public enum Step: Equatable {
        case loading
        /// Reviewing the fetched, digest-pinned manifest — the consent
        /// surface itself.
        case reviewing
        case applying
        case done
        /// Terminal: the entry can never be consented through this
        /// surface — either no fetch could happen (moderation seat, no
        /// fetchable manifest URL), the fetched manifest failed an
        /// entry cross-check (operator key / seat / componentId), or
        /// the consent store is corrupt (every accept is refused until
        /// the history is explicitly cleared elsewhere). The
        /// fetch is digest-pinned to the catalog entry, so a refetch
        /// can only return the same bytes and repeat the mismatch — no
        /// retry can change the outcome, and the view renders the
        /// error WITHOUT a Retry button. Distinct from `.loading` +
        /// `errorMessage`, which is a failed fetch that retrying may
        /// well fix.
        case failed
    }

    public let entry: AttributedCatalogEntry

    public private(set) var step: Step = .loading
    /// The exact manifest on the consent surface. Being a
    /// `ReviewedServiceManifest`, it can only have come from the
    /// reviewer's verified path — what's shown is what gets pinned.
    public private(set) var reviewed: ReviewedServiceManifest?
    public private(set) var errorMessage: String?
    /// Offers the entitlement layer currently grants (free tier today).
    public private(set) var entitledOfferIds: Set<String> = []
    /// The offer the accept will record, when the manifest carries any.
    public var selectedOfferId: String?

    private let fetchManifestBytes: @Sendable (URL) async throws -> Data
    private let consentStore: any PinnedConsentStore
    private let selectionStore: any SeatSelectionStore
    /// Entitlement provider for the manifest under review. A factory,
    /// not an instance, because the right provider depends on the
    /// manifest being reviewed: a consent-store-backed provider alone
    /// is circular on first consent (no record exists yet, so every
    /// offer — free ones included — would gate as not-entitled exactly
    /// when this surface needs an answer). The composition root passes
    /// `FreeTierEntitlementProvider(reviewing:consentStore:)`.
    private let makeEntitlements: @Sendable (SignedServiceManifest) -> any EntitlementProviding
    /// Seat-specific: write the consented manifest's endpoint into the
    /// seat's legacy configuration (the operational source of truth).
    /// Throwing — a manifest without a usable endpoint must surface as
    /// an error, never as a silent no-op behind "Service added".
    private let apply: (SignedServiceManifest) async throws -> Void
    /// Called after a successful accept so the presenter can dismiss
    /// and refresh its consent badges.
    private let onAccepted: @MainActor () -> Void
    /// Internal so tests can await completion.
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// The in-flight accept, internal so tests can await completion.
    @ObservationIgnored private(set) var acceptTask: Task<Void, Never>?

    public init(
        entry: AttributedCatalogEntry,
        fetchManifestBytes: @escaping @Sendable (URL) async throws -> Data,
        consentStore: any PinnedConsentStore,
        selectionStore: any SeatSelectionStore,
        makeEntitlements: @escaping @Sendable (SignedServiceManifest) -> any EntitlementProviding,
        apply: @escaping (SignedServiceManifest) async throws -> Void,
        onAccepted: @escaping @MainActor () -> Void = {}
    ) {
        self.entry = entry
        self.fetchManifestBytes = fetchManifestBytes
        self.consentStore = consentStore
        self.selectionStore = selectionStore
        self.makeEntitlements = makeEntitlements
        self.apply = apply
        self.onAccepted = onAccepted
    }

    // MARK: - Read helpers

    /// Display name: the manifest's `name` when published, else the
    /// component id minus its `onym:component:` prefix.
    public var displayName: String {
        if let reviewed,
           let object = try? JSONSerialization.jsonObject(with: reviewed.signedManifest.rawBytes) as? [String: Any],
           let name = object["name"] as? String, !name.isEmpty {
            return name
        }
        return Self.shortComponentId(entry.entry.componentId)
    }

    /// `terms` / `termsUri` https URL out of the manifest's raw bytes,
    /// when the operator linked terms.
    public var termsURL: URL? {
        guard let reviewed,
              let object = try? JSONSerialization.jsonObject(with: reviewed.signedManifest.rawBytes) as? [String: Any]
        else { return nil }
        for key in ["termsUri", "terms"] {
            if let value = object[key] as? String,
               let url = URL(string: value),
               url.scheme?.lowercased() == "https" {
                return url
            }
        }
        return nil
    }

    /// Grouped fingerprint of the operator key the manifest is signed
    /// by — same format as the provider TOFU screen.
    public var operatorKeyFingerprint: String? {
        reviewed.map { DiscoverySource.fingerprint(ofKeyHex: $0.signedManifest.operatorPublicKeyHex) }
    }

    public static func shortComponentId(_ componentId: String) -> String {
        let prefix = "onym:component:"
        return componentId.hasPrefix(prefix)
            ? String(componentId.dropFirst(prefix.count))
            : componentId
    }

    /// Whether Accept may be tapped. A manifest without offers is
    /// acceptable as-is; a manifest WITH offers requires a selected,
    /// entitled offer — otherwise accepting would adopt a service under
    /// commercial terms the user never (or could never) pick, e.g. a
    /// paid-only manifest pre-StoreKit.
    public var canAccept: Bool {
        guard let reviewed else { return false }
        let offers = reviewed.signedManifest.offers
        if offers.isEmpty { return true }
        guard let selectedOfferId else { return false }
        return entitledOfferIds.contains(selectedOfferId)
    }

    // MARK: - Lifecycle

    /// Fetch + review the entry's manifest. Idempotent while loading;
    /// `tappedRetry` re-arms after a failure.
    public func start() {
        guard loadTask == nil, reviewed == nil else { return }
        loadTask = Task { [weak self] in
            await self?.load()
            self?.loadTask = nil
        }
    }

    public func tappedRetry() {
        // `.failed` is terminal — nothing about the entry changes on a
        // refetch, so there is no retry to arm.
        guard step != .failed else { return }
        errorMessage = nil
        step = .loading
        start()
    }

    private func load() async {
        // Defense in depth: the pickers only pass transport / notary /
        // blob entries, but a moderation entry must never reach this
        // surface — its consent is a signed mandate. Terminal: no
        // retry can make this entry acceptable here.
        guard entry.entry.seatType != ModuleConsentAcceptance.excludedSeatType else {
            errorMessage = String(localized: "Moderation authorities are consented through the moderation flow.")
            step = .failed
            return
        }
        // Equally terminal: the entry carries no fetchable manifest
        // URL, so a retry has nothing to fetch.
        guard let url = entry.entry.manifest.url else {
            errorMessage = String(localized: "This entry has no fetchable manifest URL.")
            step = .failed
            return
        }
        do {
            let bytes = try await fetchManifestBytes(url)
            // Hard-enforced review: digest pin from the verified
            // catalog entry, embedded operator signature over the
            // exact bytes, expiry.
            let token = try ServiceManifestReviewer().review(
                raw: bytes,
                expectedDigest: entry.entry.manifest.digest
            )
            // The catalog is the verified side of this trust chain:
            // a fetched manifest naming a different operator key than
            // the entry is rejected, digest pin notwithstanding.
            // Terminal (`.failed`, no Retry): the fetch is pinned to
            // the entry's digest, so a refetch can only return the
            // same bytes and repeat the mismatch — same
            // no-retry-that-can't-succeed rule as the guards above.
            guard token.signedManifest.operatorKey == entry.entry.operatorKey else {
                errorMessage = String(localized: "The service's manifest names a different operator key than the catalog entry. Not safe to accept.")
                step = .failed
                return
            }
            guard token.signedManifest.seat == entry.entry.seatType else {
                errorMessage = String(localized: "The service's manifest declares a different seat than the catalog entry. Not safe to accept.")
                step = .failed
                return
            }
            // Same hard rule for the component identity: a manifest
            // naming a different componentId than the entry would
            // record consent under one id while the catalog rows look
            // it up by the other — the row would stay "REVIEW" forever
            // and every accept would append another consent record.
            guard token.signedManifest.componentId == entry.entry.componentId else {
                errorMessage = String(localized: "The service's manifest names a different component than the catalog entry. Not safe to accept.")
                step = .failed
                return
            }
            reviewed = token
            // A reload after a failure must not carry a stale
            // selection into the fresh entitlement computation: the
            // preselect-first-entitled logic only runs on nil, and a
            // leftover id could name an offer this manifest no longer
            // carries (or no longer entitles).
            selectedOfferId = nil
            await computeEntitlements(for: token.signedManifest)
            step = .reviewing
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func computeEntitlements(for manifest: SignedServiceManifest) async {
        // Resolved against the manifest CURRENTLY under review — see
        // `makeEntitlements`. On first consent there is no pinned
        // record, and on re-review the record may describe an older
        // manifest; the reviewed offers are the authority either way.
        let entitlements = makeEntitlements(manifest)
        var entitled = Set<String>()
        for offer in manifest.offers {
            if await entitlements.entitlement(for: offer.offerId, component: manifest.componentId) != nil {
                entitled.insert(offer.offerId)
            }
        }
        entitledOfferIds = entitled
        // Preselect the first offer the user could actually take.
        if selectedOfferId == nil {
            selectedOfferId = manifest.offers.first { entitled.contains($0.offerId) }?.offerId
        }
    }

    // MARK: - Accept

    /// "Accept" on the consent surface. Pins the exact reviewed bytes,
    /// records the selection provenance, then applies the endpoint to
    /// the seat's legacy configuration.
    public func tappedAccept() {
        guard let reviewed, step == .reviewing, canAccept else { return }
        step = .applying
        errorMessage = nil
        acceptTask = Task {
            // Retry-after-apply-failure guard: when the ACTIVE consent
            // already pins these exact bytes AND the same offer (a
            // previous accept succeeded and only `apply` failed, e.g.
            // `noUsableEndpoint`), retry ONLY the apply — re-running
            // accept would append a fresh consent record + selection
            // per tap for the same manifest. The offerId is part of
            // the check on purpose: a retry after the user changed
            // `selectedOfferId` must take the FULL accept path (the
            // store's accept deactivates-and-appends, superseding the
            // record), or the pinned record and `ModuleSelection`
            // would keep the ORIGINAL offer while the screen shows
            // the new selection.
            let manifest = reviewed.signedManifest
            // `try?` is fail-closed here: a store that throws (corrupt
            // records) reads as "not already pinned", so the accept
            // below runs and surfaces the store's refusal honestly
            // instead of skipping straight to apply.
            let activeRecord = try? consentStore
                .activeRecord(componentId: manifest.componentId)
            let alreadyPinned = activeRecord?.manifestHash == manifest.manifestHash
                && activeRecord?.offerId == selectedOfferId
            if !alreadyPinned {
                do {
                    try ModuleConsentAcceptance.accept(
                        reviewed: reviewed,
                        source: entry.source,
                        offerId: selectedOfferId,
                        consentStore: consentStore,
                        selectionStore: selectionStore
                    )
                } catch ModuleConsentError.moderationSeatExcluded {
                    // Not transient — retrying can never succeed. The
                    // pickers shouldn't let a moderation entry reach
                    // this surface, but if one does, say what's wrong
                    // instead of "Try again".
                    step = .reviewing
                    errorMessage = String(localized: "This is a moderation authority — its consent is a signed mandate, so it can't be added here. Use the moderation settings instead.")
                    return
                } catch PinnedConsentStoreError.corruptStore {
                    // Not transient either — the store refuses every
                    // accept until the corrupt history is explicitly
                    // cleared, so nothing this surface can do makes
                    // another attempt succeed. TERMINAL `.failed`
                    // (rendered without any retry affordance), same
                    // no-retry-that-can't-succeed rule as the entry
                    // cross-check failures.
                    step = .failed
                    errorMessage = String(localized: "Your consent history couldn't be read, so this consent can't be recorded. Nothing was changed.")
                    return
                } catch {
                    step = .reviewing
                    errorMessage = String(localized: "Couldn't record consent. Try again.")
                    return
                }
            }
            do {
                try await apply(reviewed.signedManifest)
                step = .done
                onAccepted()
            } catch ModuleApplyError.noUsableEndpoint {
                // The consent IS pinned (accept succeeded); only the
                // configuration write failed. Be honest about both
                // halves rather than showing "Service added".
                step = .reviewing
                errorMessage = String(localized: "The service was reviewed and your consent was recorded, but it wasn't added: its manifest lists no endpoint this seat can use.")
            } catch {
                step = .reviewing
                errorMessage = String(localized: "The service was reviewed and your consent was recorded, but it couldn't be added to your configuration.")
            }
        }
    }

    // MARK: - Private

    private static func message(for error: Error) -> String {
        switch error {
        case ServiceManifestError.digestMismatch:
            return String(localized: "The fetched manifest doesn't match the bytes the catalog reviewed. Not safe to accept.")
        case let ServiceManifestError.signatureInvalid(reason):
            return String(localized: "The manifest's signature failed verification (\(reason)).")
        case let ServiceManifestError.manifestInvalid(reason):
            return String(localized: "The manifest is malformed (\(reason)).")
        case ServiceManifestError.expired:
            return String(localized: "The manifest has expired. The operator needs to publish a fresh one.")
        default:
            return String(localized: "Couldn't load the service's manifest. Try again.")
        }
    }
}
