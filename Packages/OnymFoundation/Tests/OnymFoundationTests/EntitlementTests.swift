import Foundation
import XCTest
@testable import OnymFoundation

final class EntitlementTests: XCTestCase {
    private static let componentId = "onym:component:sample-notary"

    private let provider = FreeTierEntitlementProvider { offerId, componentId in
        guard componentId == EntitlementTests.componentId else { return nil }
        switch offerId {
        case "free-tier": return ServiceOffer(offerId: "free-tier", model: "free")
        case "pro-monthly": return ServiceOffer(offerId: "pro-monthly", model: "subscription", period: "monthly")
        case "boost-pack": return ServiceOffer(offerId: "boost-pack", model: "consumable")
        default: return nil
        }
    }

    func testGrantsFreeOfferWithoutExpiry() async {
        let entitlement = await provider.entitlement(for: "free-tier", component: Self.componentId)
        XCTAssertEqual(
            entitlement,
            ServiceEntitlement(offerId: "free-tier", componentId: Self.componentId, expiresAt: nil)
        )
    }

    func testRefusesPaidOffers() async {
        let subscription = await provider.entitlement(for: "pro-monthly", component: Self.componentId)
        XCTAssertNil(subscription)
        let consumable = await provider.entitlement(for: "boost-pack", component: Self.componentId)
        XCTAssertNil(consumable)
    }

    func testRefusesUnknownOfferAndUnknownComponent() async {
        let unknownOffer = await provider.entitlement(for: "no-such-offer", component: Self.componentId)
        XCTAssertNil(unknownOffer)
        let unknownComponent = await provider.entitlement(for: "free-tier", component: "onym:component:other")
        XCTAssertNil(unknownComponent)
    }

    /// The first-consent moment: NO consent record exists yet, so a
    /// store-backed lookup answers nil for everything — the manifest
    /// under review must be the authority on its own offers, or free
    /// offers can never be selected the first time around.
    func testReviewingProviderGrantsFreeOfferBeforeAnyConsentExists() async throws {
        let suiteName = "EntitlementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let emptyStore = UserDefaultsPinnedConsentStore(defaults: defaults)
        let manifest = try ManifestFactory.reviewedSample().signedManifest

        let provider = FreeTierEntitlementProvider(reviewing: manifest, consentStore: emptyStore)
        let free = await provider.entitlement(for: "free-tier", component: manifest.componentId)
        XCTAssertEqual(
            free,
            ServiceEntitlement(offerId: "free-tier", componentId: manifest.componentId, expiresAt: nil),
            "a free offer of the manifest under review must be granted on first consent"
        )
        let paid = await provider.entitlement(for: "pro-monthly", component: manifest.componentId)
        XCTAssertNil(paid, "paid offers stay refused until a real entitlement layer exists")
        let unknown = await provider.entitlement(for: "no-such-offer", component: manifest.componentId)
        XCTAssertNil(unknown)
    }

    /// For components OTHER than the one under review, the active
    /// consent record remains the offer source.
    func testReviewingProviderFallsBackToConsentStoreForOtherComponents() async throws {
        let suiteName = "EntitlementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPinnedConsentStore(defaults: defaults)
        // The store knows sample-notary; the review is over another
        // component entirely.
        try store.accept(try ManifestFactory.reviewedSample(), acceptedAt: ManifestFactory.now)
        let reviewing = try ManifestFactory.reviewedSample { object in
            object["componentId"] = "onym:component:other-notary"
        }.signedManifest

        let provider = FreeTierEntitlementProvider(reviewing: reviewing, consentStore: store)
        let storeBacked = await provider.entitlement(for: "free-tier", component: Self.componentId)
        XCTAssertNotNil(storeBacked, "other components still resolve through the active record")
        let reviewed = await provider.entitlement(for: "free-tier", component: reviewing.componentId)
        XCTAssertNotNil(reviewed)
    }

    func testConsentStoreBackedProviderGrantsFreeAndRefusesPaid() async throws {
        let suiteName = "EntitlementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPinnedConsentStore(defaults: defaults)
        try store.accept(try ManifestFactory.reviewedSample(), acceptedAt: ManifestFactory.now)

        let provider = FreeTierEntitlementProvider(consentStore: store)
        let free = await provider.entitlement(for: "free-tier", component: Self.componentId)
        XCTAssertNotNil(free)
        let paid = await provider.entitlement(for: "pro-monthly", component: Self.componentId)
        XCTAssertNil(paid)
        let unconsented = await provider.entitlement(for: "free-tier", component: "onym:component:other")
        XCTAssertNil(unconsented)
    }
}
