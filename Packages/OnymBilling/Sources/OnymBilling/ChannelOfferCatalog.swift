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

    public init(offers: [ChannelOffer]) {
        self.offers = offers
    }

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

    /// Product identifiers listed more than once. Empty in a
    /// well-formed catalog; surfaced so a build can fail on it rather
    /// than discovering it during a replay.
    public var duplicateProductIds: [String] {
        Dictionary(grouping: offers, by: \.productId)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
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
        let matches = offers.filter { $0.productId == productId }
        guard matches.count == 1 else {
            // Ambiguous or absent. Refusing is right for both: a replay
            // we cannot attribute is left unfinished and retried, which
            // is recoverable, where crediting the wrong operator is not.
            assert(matches.count < 2, "channel offers share productId \(productId)")
            return nil
        }
        return matches[0]
    }

    public var productIds: Set<String> { Set(offers.map(\.productId)) }
}
