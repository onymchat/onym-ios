import Foundation

/// Proof that this device may use one of a service's offers. Minimal
/// on purpose: the StoreKit-backed provider that replaces the free
/// stub carries receipts elsewhere — consumers only need to know
/// *whether* and *until when*.
public struct ServiceEntitlement: Sendable, Equatable {
    public let offerId: String
    public let componentId: String
    /// `nil` means no expiry (free tiers, lifetime purchases).
    public let expiresAt: Date?

    public init(offerId: String, componentId: String, expiresAt: Date? = nil) {
        self.offerId = offerId
        self.componentId = componentId
        self.expiresAt = expiresAt
    }
}

/// Gate on paid offers. The UI asks this before letting an offer be
/// selected; `nil` means not entitled. StoreKit slots in behind this
/// seam later without touching consent or discovery.
public protocol EntitlementProviding: Sendable {
    func entitlement(for offerId: String, component componentId: String) async -> ServiceEntitlement?
}

/// The pre-StoreKit stub: free offers are granted unconditionally and
/// without expiry, everything else — paid models, unknown models,
/// offers it cannot find — is refused.
///
/// Whether an offer is free lives in the service's manifest, so the
/// provider takes a lookup closure instead of duplicating that state;
/// the app supplies one over its pinned consents or catalog entries.
public struct FreeTierEntitlementProvider: EntitlementProviding {
    private let offerLookup: @Sendable (_ offerId: String, _ componentId: String) -> ServiceOffer?

    public init(
        offerLookup: @escaping @Sendable (_ offerId: String, _ componentId: String) -> ServiceOffer?
    ) {
        self.offerLookup = offerLookup
    }

    /// Convenience over the consent store: resolves offers from the
    /// active pinned manifest of the component in question.
    ///
    /// Cost note: every check is a full store `load()` (defaults read
    /// + JSON decode of all records) plus a manifest re-decode — by
    /// design, so entitlement answers can never go stale against the
    /// store. Fine for action-time checks; a UI that polls this per
    /// frame or per row should resolve the offer once and hold it, or
    /// supply a caching `offerLookup` instead.
    public init(consentStore: any PinnedConsentStore) {
        self.init { offerId, componentId in
            consentStore.activeRecord(componentId: componentId)?
                .consentedManifest()?
                .offers
                .first { $0.offerId == offerId }
        }
    }

    public func entitlement(for offerId: String, component componentId: String) async -> ServiceEntitlement? {
        guard let offer = offerLookup(offerId, componentId), offer.isFree else { return nil }
        return ServiceEntitlement(offerId: offerId, componentId: componentId, expiresAt: nil)
    }
}
