import CryptoKit
import Foundation
import OnymFoundation

/// The `EntitlementProviding` conformer that finally lets a paid offer
/// be selected.
///
/// Composed with `FreeTierEntitlementProvider` rather than replacing it:
/// a free offer must still resolve with no network, no store, and no
/// credential, because a self-hosted operator charging nothing is a
/// first-class case and not a degraded one.
///
/// Fail-closed at every step. An entitlement that cannot be verified is
/// not an entitlement, and the honest answer to "may this person use
/// this offer" is `nil` rather than an optimistic yes.
public struct StoreKitEntitlementProvider: EntitlementProviding {
    private let free: FreeTierEntitlementProvider
    private let catalog: ChannelOfferCatalog
    private let store: any SeatEntitlementStoring
    private let keys: any SeatAccessKeyProviding
    /// Issuer references the operator names in its manifest, by
    /// component. Pinned upstream; this type never learns them from an
    /// entitlement.
    private let trustedIssuers: @Sendable (String) -> [String]
    private let revokedIds: @Sendable () async -> Set<String>
    private let now: @Sendable () -> Date

    public init(
        free: FreeTierEntitlementProvider,
        catalog: ChannelOfferCatalog,
        store: any SeatEntitlementStoring,
        keys: any SeatAccessKeyProviding,
        trustedIssuers: @escaping @Sendable (String) -> [String],
        revokedIds: @escaping @Sendable () async -> Set<String> = { [] },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.free = free
        self.catalog = catalog
        self.store = store
        self.keys = keys
        self.trustedIssuers = trustedIssuers
        self.revokedIds = revokedIds
        self.now = now
    }

    public func entitlement(
        for offerId: String,
        component componentId: String
    ) async -> ServiceEntitlement? {
        // Free first, and without touching anything else.
        if let free = await free.entitlement(for: offerId, component: componentId) {
            return free
        }
        // An offer with no store product cannot be sold here. Saying so
        // by returning nil is more honest than a network round trip that
        // was never going to succeed.
        guard catalog.offer(forOfferId: offerId, componentId: componentId) != nil else {
            return nil
        }
        // `try?` here is deliberate and is the opposite call from
        // `SeatPurchaseFlow.redeem`, which propagates. This asks "may
        // this offer be selected right now"; an unreadable store — a
        // locked device at launch, say — means we cannot say yes, and
        // fail-closed is the honest answer. `redeem` propagates because
        // it goes on to *write*, and answering "no entitlements" there
        // would overwrite the ones it could not read.
        guard
            let subject = try? await keys.seatSubject(componentId: componentId),
            let stored = try? store.load()
        else {
            return nil
        }

        let verifier = SeatEntitlementVerifier(
            trustedIssuers: trustedIssuers(componentId),
            componentId: componentId,
            subject: subject
        )
        let revoked = await revokedIds()
        let currentTime = now()

        for raw in stored {
            guard
                let entitlement = try? SeatEntitlement.decode(raw: raw),
                entitlement.offerId == offerId,
                (try? verifier.verify(entitlement, now: currentTime, revokedIds: revoked)) != nil
            else {
                continue
            }
            return ServiceEntitlement(
                offerId: offerId,
                componentId: componentId,
                expiresAt: entitlement.expiresAt
            )
        }
        return nil
    }
}
