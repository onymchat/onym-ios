import Foundation

/// Maps a seat operator's offer to a store product this app can actually
/// sell.
///
/// The mapping is a business arrangement, not a runtime lookup: a store
/// product is configured before it can be sold, so an arbitrary operator
/// cannot turn its manifest into a purchasable product by publishing one
/// (`WHITEPAPER.md` §16.1). An offer with no entry here is presented as
/// not purchasable through this app — which is a true statement about
/// this app, not a judgement about the operator.
public struct ChannelOffer: Sendable, Equatable, Codable {
    public let channelOfferId: String
    public let componentId: String
    public let offerId: String
    public let productId: String
    /// `auto-renewable-subscription` or `consumable`.
    public let productType: String
    /// The share the operator receives, in basis points, of what the
    /// platform actually remits to the publisher — never of the
    /// storefront price. Carried so the consent surface can show it:
    /// a commission a person cannot see is not disclosed.
    public let operatorShareBps: Int
    public let frontendCommissionBps: Int

    public var isSubscription: Bool { productType == "auto-renewable-subscription" }
}

/// The bundled catalog.
public struct ChannelOfferCatalog: Sendable {
    private let offers: [ChannelOffer]

    /// Duplicated product identifiers are **dropped at construction**,
    /// not asserted at lookup.
    ///
    /// An assert crashes a debug build in the middle of a replay, which
    /// is the opposite of the refuse-and-retry the lookup promises, and
    /// does nothing at all in Release. Dropping both sides of a clash
    /// means the catalog is well-formed by construction: the affected
    /// offer becomes unsellable, which is visible and safe, rather than
    /// crediting a purchase to whichever operator sorted first.
    public init(offers: [ChannelOffer]) {
        let duplicated = Set(
            Dictionary(grouping: offers, by: \.productId)
                .filter { $0.value.count > 1 }
                .keys)
        self.offers = offers.filter { !duplicated.contains($0.productId) }
        self.rejectedProductIds = duplicated.sorted()
    }

    /// Product identifiers dropped as ambiguous. Empty in a well-formed
    /// catalog; surfaced so a build or a diagnostic can notice.
    public let rejectedProductIds: [String]

    /// Load from a bundled JSON resource.
    ///
    /// Committed, not gitignored: this is public commercial mapping —
    /// which product sells which seat, and on what split — not a secret.
    /// A missing or unreadable file yields an empty catalog, which
    /// presents every paid offer as not purchasable rather than
    /// pretending one is.
    public static func bundled(
        named name: String = "ChannelOffers",
        in bundle: Bundle = .main
    ) -> ChannelOfferCatalog {
        guard
            let url = bundle.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let offers = try? JSONDecoder().decode([ChannelOffer].self, from: data)
        else {
            return ChannelOfferCatalog(offers: [])
        }
        return ChannelOfferCatalog(offers: offers)
    }

    public func offer(forOfferId offerId: String, componentId: String) -> ChannelOffer? {
        offers.first { $0.offerId == offerId && $0.componentId == componentId }
    }

    /// The reverse lookup a `Transaction.updates` replay needs: StoreKit
    /// hands back a product identifier, and only the catalog knows which
    /// seat and offer it was bought for.
    ///
    /// **A `productId` must appear at most once.** The reverse lookup has
    /// no other way to choose, so two components sharing a product would
    /// redeem a replayed transaction for whichever sorted first —
    /// crediting one operator for a purchase made from another. Checked
    /// at load rather than left as a convention.
    public func offer(forProductId productId: String) -> ChannelOffer? {
        // Unambiguous by construction — a clash was dropped at load — so
        // a miss here means the product is not ours to redeem, and the
        // replay is left unfinished and retried rather than attributed
        // to a guess.
        offers.first { $0.productId == productId }
    }

    public var productIds: Set<String> { Set(offers.map(\.productId)) }
}
