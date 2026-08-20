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

    /// What a restore sweep found.
    public struct RestoreResult: Sendable, Equatable {
        /// Offers this device now holds a verified credential for.
        public let restored: [String]
        /// Offers already covered before the sweep ran.
        public let alreadyHeld: [String]
        /// Whether the check for what is already held could not be
        /// made — an unreadable credential store, or a subject that
        /// could not be derived.
        ///
        /// The sweep still runs, re-redeeming everything, which is the
        /// safe direction. It is reported because "this phone is
        /// already set up" and "this phone could not tell" are
        /// different answers and only one of them is a reason to stop
        /// looking.
        public let heldUnknown: Bool
        /// Offers the store *did* have an entitlement for and this
        /// device could not turn into a credential, by offer id.
        ///
        /// Sentences, not enum dumps: one of these is rendered straight
        /// onto the Device Backup screen, and the difference between
        /// getting what you paid for and buying it twice is what that
        /// row is for.
        public let failures: [String: String]

        public var isEmpty: Bool { restored.isEmpty && alreadyHeld.isEmpty }

        public init(
            restored: [String],
            alreadyHeld: [String],
            heldUnknown: Bool,
            failures: [String: String]
        ) {
            self.restored = restored
            self.alreadyHeld = alreadyHeld
            self.heldUnknown = heldUnknown
            self.failures = failures
        }
    }

    /// Ask the store to sync before a sweep.
    ///
    /// Separate, and only ever an explicit action: `AppStore.sync()`
    /// prompts for App Store authentication, and a screen that demands a
    /// password on appear is a screen people learn to back out of. The
    /// silent sweep below needs none of it.
    public func syncWithStore() async throws {
        try await coordinator.sync()
    }

    /// Recover credentials for purchases this device did not make.
    ///
    /// The new-phone path, and the reason it needs its own method:
    /// `Transaction.updates` replays only transactions that were never
    /// *finished*, and a purchase completed on the old phone was
    /// finished there. On the new one it exists solely in
    /// `Transaction.currentEntitlement`, which nothing was asking.
    /// Without this, someone who restored their identity from the
    /// recovery phrase met `payment_required` at an operator they had
    /// already paid, and the only offered way out was to pay again.
    ///
    /// Everything the broker needs is derivable from the recovery
    /// phrase: the subject is the seat access key for this operator, and
    /// the credential is sealed to the agreement key derived beside it.
    /// So this works on a device that has never seen the old one.
    ///
    /// One offer failing does not stop the others, and a failure is
    /// reported rather than swallowed — a sweep that quietly restored
    /// nothing would look identical to one that had nothing to restore.
    public func restorePurchases(componentId: String) async -> RestoreResult {
        var restored: [String] = []
        var alreadyHeld: [String] = []
        var failures: [String: String] = [:]

        var held: Set<String> = []
        var heldUnknown = false
        do {
            held = try await heldOfferIds(componentId: componentId)
        } catch {
            // Could not tell. Everything is re-checked, which is the
            // safe direction — but it is not the same as knowing
            // nothing is held, and the caller is told which one this
            // was.
            heldUnknown = true
        }
        for channelOffer in catalog.offers(forComponentId: componentId) {
            if held.contains(channelOffer.offerId) {
                // A credential that still verifies needs no broker round
                // trip. Redeeming anyway would spend the person's
                // network and the broker's rate limit to arrive back
                // where we started.
                alreadyHeld.append(channelOffer.offerId)
                continue
            }
            let current: (jws: String, transaction: StoreKit.Transaction)?
            do {
                current = try await coordinator.currentTransaction(for: channelOffer.productId)
            } catch {
                // The store had something and it did not verify. That is
                // not "never bought", and reporting it as such is how
                // somebody pays twice.
                failures[channelOffer.offerId] = Self.describe(error)
                continue
            }
            guard let (jws, transaction) = current else {
                // The ordinary answer for something never bought, or a
                // subscription that lapsed. Not an error, and not
                // counted as one.
                continue
            }
            do {
                _ = try await redeem(
                    signedTransaction: jws,
                    offerId: channelOffer.offerId,
                    componentId: componentId
                )
                restored.append(channelOffer.offerId)
                // Ordinarily already finished — this transaction came
                // from `currentEntitlement`, not from a purchase. It is
                // called anyway for the case that is not ordinary: a
                // purchase made on this device whose redemption never
                // completed, which is delivered now.
                await coordinator.finish(transaction)
            } catch {
                failures[channelOffer.offerId] = Self.describe(error)
            }
        }
        return RestoreResult(
            restored: restored,
            alreadyHeld: alreadyHeld,
            heldUnknown: heldUnknown,
            failures: failures
        )
    }

    /// A sentence somebody can act on.
    ///
    /// `String(describing:)` on a `BillingError` produces
    /// `brokerRejected(code: "invalid_transaction", message: Optional("…"))`
    /// — a debugger's output, rendered at a person trying to find out
    /// whether the subscription they paid for came across. Every error
    /// this can see already knows how to say itself; anything that does
    /// not gets a sentence rather than its type name.
    static func describe(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "This phone is not online, so the App Store could not be checked."
        }
        return "The purchase could not be restored on this device."
    }

    /// Offers this device already holds a credential for that verifies
    /// today — not merely one that is stored.
    private func heldOfferIds(componentId: String) async throws -> Set<String> {
        let subject = try await keys.seatSubject(componentId: componentId)
        let verifier = SeatEntitlementVerifier(
            trustedIssuers: trustedIssuers(componentId),
            componentId: componentId,
            subject: subject
        )
        var offerIds: Set<String> = []
        for raw in try store.load() {
            guard
                let entitlement = try? SeatEntitlement.decode(raw: raw),
                (try? verifier.verify(entitlement)) != nil
            else {
                // Expired, revoked, or for somebody else. Not held, so
                // the sweep should try to replace it — which is exactly
                // what a lapsed subscription that has since been renewed
                // needs.
                continue
            }
            offerIds.insert(entitlement.offerId)
        }
        return offerIds
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

        // Not `try?`. A failed load inside the mutation propagates
        // rather than being followed by a save that writes only this
        // credential over every other one — and this is the
        // `Transaction.updates` replay path, which fires at launch,
        // where a read can legitimately fail because the file is under
        // complete protection and the device has not been unlocked. One
        // replayed transaction would then destroy every purchase the
        // person had made.
        //
        // Throwing leaves the transaction unfinished, so the store
        // replays it once the device is readable. A delayed credential
        // is recoverable; deleted credentials are not.
        // One step, under the store's lock. A `load()` here and a
        // `save()` three lines later is a read-modify-write across a
        // shared file, and every `SeatPurchaseFlow` is a separate actor
        // instance — the replay observer and a restore sweep redeeming
        // at once would drop one of the two credentials, permanently,
        // because a redeemed transaction is finished and never replayed.
        try store.mutate { stored in
            var stored = stored
            // One live credential per offer. Keeping the superseded one
            // would leave a verifier free to pick either.
            //
            // Entries this build cannot decode are *kept*. A newer
            // client may have written a version we do not understand,
            // and an older build silently deleting it during an
            // unrelated redeem is a downgrade that eats data. Only
            // positively matched entries go.
            stored.removeAll { existing in
                guard let decoded = try? SeatEntitlement.decode(raw: existing) else { return false }
                return decoded.audience == componentId && decoded.offerId == offerId
            }
            stored.append(raw)
            return stored
        }
        return entitlement
    }
}
