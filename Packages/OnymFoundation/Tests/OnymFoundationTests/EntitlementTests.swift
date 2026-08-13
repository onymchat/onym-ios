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

    func testConsentStoreBackedProviderGrantsFreeAndRefusesPaid() async throws {
        let suiteName = "EntitlementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPinnedConsentStore(defaults: defaults)
        store.accept(try ManifestFactory.reviewedSample(), acceptedAt: ManifestFactory.now)

        let provider = FreeTierEntitlementProvider(consentStore: store)
        let free = await provider.entitlement(for: "free-tier", component: Self.componentId)
        XCTAssertNotNil(free)
        let paid = await provider.entitlement(for: "pro-monthly", component: Self.componentId)
        XCTAssertNil(paid)
        let unconsented = await provider.entitlement(for: "free-tier", component: "onym:component:other")
        XCTAssertNil(unconsented)
    }
}
