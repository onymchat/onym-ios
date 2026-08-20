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

    /// The Ed25519 keys behind a set of `onym:key:` references.
    ///
    /// An unparseable reference is dropped rather than failing the whole
    /// set; the caller refuses if that leaves nothing.
    static func senderKeys(from references: [String]) -> [Curve25519.Signing.PublicKey] {
        references.compactMap { reference in
            guard
                let bytes = BillingFormat.publicKeyBytes(
                    from: reference, prefix: BillingFormat.keyPrefix),
                let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
            else {
                return nil
            }
            return key
        }
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
        // The sender is pinned to the operator's declared issuers.
        // Sealing proves only that the answer was meant for this device;
        // without this, an envelope signed by anyone — or by nobody —
        // opens, and the sender-authentication path exists but never
        // runs.
        //
        // An empty set is refused rather than passed through as "accept
        // unauthenticated". It cannot succeed anyway — the verifier
        // below requires a trusted issuer — but failing here says why,
        // instead of opening an unauthenticated envelope and reporting a
        // signature problem two steps later.
        let senders = Self.senderKeys(from: trustedIssuers(componentId))
        guard !senders.isEmpty else {
            throw BillingError.untrustedIssuer(issuer: componentId)
        }
        let raw = try SeatSealedEnvelope.open(
            envelopeBytes: sealed,
            recipient: agreementKey,
            expectedSenders: senders
        )
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

        // Not `try?`. A failed load here would be followed by a save
        // that writes only this credential over every other one — and
        // this is the `Transaction.updates` replay path, which fires at
        // launch, where a read can legitimately fail because the file is
        // under complete protection and the device has not been
        // unlocked. One replayed transaction would then destroy every
        // purchase the person had made.
        //
        // Throwing leaves the transaction unfinished, so the store
        // replays it once the device is readable. A delayed credential
        // is recoverable; deleted credentials are not.
        var stored = try store.load()

        // One live credential per offer. Keeping the superseded one
        // would leave a verifier free to pick either.
        //
        // Entries this build cannot decode are *kept*. A newer client
        // may have written a version we do not understand, and an older
        // build silently deleting it during an unrelated redeem is a
        // downgrade that eats data. Only positively matched entries go.
        stored.removeAll { existing in
            guard let decoded = try? SeatEntitlement.decode(raw: existing) else { return false }
            return decoded.audience == componentId && decoded.offerId == offerId
        }
        stored.append(raw)
        try store.save(stored)
        return entitlement
    }
}
