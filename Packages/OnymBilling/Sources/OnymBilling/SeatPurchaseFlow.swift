import CryptoKit
import Foundation
import StoreKit

/// Buy a seat's offer and turn the receipt into a credential.
///
/// The sequence is the one `WHITEPAPER.md` §17.3 describes, and its
/// ordering is the substance: the store signs a transaction, the broker
/// validates it with the platform and issues a credential, we verify
/// that credential ourselves, store it, and only then tell the store the
/// purchase was delivered.
///
/// Finishing the transaction last is what makes a broker outage
/// survivable. An unfinished transaction is replayed by
/// `Transaction.updates`, so someone who paid and lost the network gets
/// their credential on the next launch instead of a charge and nothing.
public actor SeatPurchaseFlow {
    private let coordinator: StoreKitPurchaseCoordinator
    private let broker: any BillingBrokerClient
    private let catalog: ChannelOfferCatalog
    private let store: any SeatEntitlementStoring
    private let keys: any SeatAccessKeyProviding
    private let trustedIssuers: @Sendable (String) -> [String]

    public init(
        coordinator: StoreKitPurchaseCoordinator,
        broker: any BillingBrokerClient,
        catalog: ChannelOfferCatalog,
        store: any SeatEntitlementStoring,
        keys: any SeatAccessKeyProviding,
        trustedIssuers: @escaping @Sendable (String) -> [String]
    ) {
        self.coordinator = coordinator
        self.broker = broker
        self.catalog = catalog
        self.store = store
        self.keys = keys
        self.trustedIssuers = trustedIssuers
    }

    /// Purchase `offerId` for `componentId`.
    @discardableResult
    public func purchase(offerId: String, componentId: String) async throws -> SeatEntitlement {
        guard let channelOffer = catalog.offer(forOfferId: offerId, componentId: componentId) else {
            throw BillingError.offerNotSellable(offerId: offerId)
        }
        guard
            let product = try await coordinator.products(for: [channelOffer.productId]).first
        else {
            throw BillingError.offerNotSellable(offerId: offerId)
        }
        let (jws, transaction) = try await coordinator.purchase(product)
        let entitlement = try await redeem(
            signedTransaction: jws, offerId: offerId, componentId: componentId)
        // Delivered — now the store may consider it done.
        await coordinator.finish(transaction)
        return entitlement
    }

    /// Turn a store-signed transaction into a stored credential.
    ///
    /// Also the replay path: `Transaction.updates` hands back
    /// transactions that were never finished, and each one comes through
    /// here.
    @discardableResult
    public func redeem(
        signedTransaction: String,
        offerId: String,
        componentId: String
    ) async throws -> SeatEntitlement {
        let subject = try await keys.seatSubject(componentId: componentId)
        let agreementKey = try await keys.seatAgreementKey(componentId: componentId)

        let sealed = try await broker.issueEntitlement(
            SeatEntitlementRequest(
                offerId: offerId,
                audience: componentId,
                subject: subject,
                sealTo: agreementKey.publicKey.rawRepresentation,
                signedTransaction: signedTransaction
            )
        )
        let raw = try SeatSealedEnvelope.open(envelopeBytes: sealed, recipient: agreementKey)
        let entitlement = try SeatEntitlement.decode(raw: raw)

        // Verified here, not trusted because it arrived sealed. Sealing
        // says only that it was meant for this device; the signature says
        // who issued it, and the issuer set comes from the operator's
        // manifest rather than from the document itself.
        try SeatEntitlementVerifier(
            trustedIssuers: trustedIssuers(componentId),
            componentId: componentId,
            subject: subject
        ).verify(entitlement)

        var stored = (try? store.load()) ?? []
        // One live credential per offer. Keeping the superseded one
        // would leave a verifier free to pick either.
        stored.removeAll { existing in
            guard let decoded = try? SeatEntitlement.decode(raw: existing) else { return true }
            return decoded.audience == componentId && decoded.offerId == offerId
        }
        stored.append(raw)
        try store.save(stored)
        return entitlement
    }
}
