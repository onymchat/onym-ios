import Foundation
import OnymBilling
import StoreKit

/// Watches StoreKit for transactions that were never finished.
///
/// This is what makes an interrupted purchase recoverable rather than a
/// charge with nothing to show. `SeatPurchaseFlow` finishes a
/// transaction only after a credential has been issued, verified and
/// stored — so a broker outage, a lost network, or a process death
/// between paying and redeeming leaves the transaction unfinished, and
/// StoreKit replays it here on the next launch.
///
/// Must start **before** any UI. A replay delivered while nothing is
/// listening is a replay that has to wait for the launch after next.
@MainActor
final class SeatTransactionObserver {
    /// Built per component, not once.
    ///
    /// A broker client pins the issuer key it will verify a revocation
    /// epoch against, and that key comes from the *operator's* signed
    /// manifest — so there is no such thing as an app-wide broker
    /// client. Returns `nil` when the component has no consented
    /// manifest to take an issuer from, in which case the transaction is
    /// left unfinished rather than redeemed against an unpinned broker.
    private let makeFlow: @Sendable (String) async -> SeatPurchaseFlow?
    private let catalog: ChannelOfferCatalog
    private var task: Task<Void, Never>?

    init(
        catalog: ChannelOfferCatalog,
        makeFlow: @escaping @Sendable (String) async -> SeatPurchaseFlow?
    ) {
        self.catalog = catalog
        self.makeFlow = makeFlow
    }

    func start() {
        guard task == nil else { return }
        task = Task { [makeFlow, catalog] in
            for await update in StoreKit.Transaction.updates {
                guard case .verified(let transaction) = update else {
                    // StoreKit could not verify its own signature. The
                    // broker would refuse it too, and finishing it here
                    // would tell the store a purchase was delivered
                    // when nothing was.
                    continue
                }
                guard let offer = catalog.offer(forProductId: transaction.productID) else {
                    // A product this build does not sell — a leftover
                    // from a previous catalog, or another app's sandbox
                    // state. Left unfinished rather than finished: it is
                    // not ours to close out.
                    continue
                }
                guard let flow = await makeFlow(offer.componentId) else {
                    // No consented manifest for that component, so no
                    // issuer key to pin. Redeeming against an unpinned
                    // broker would accept a credential from whoever
                    // answered.
                    continue
                }
                do {
                    _ = try await flow.redeem(
                        signedTransaction: update.jwsRepresentation,
                        offerId: offer.offerId,
                        componentId: offer.componentId
                    )
                    await transaction.finish()
                } catch {
                    // Deliberately left unfinished. Whatever failed —
                    // an unreadable credential store on a locked device,
                    // a broker outage — StoreKit will replay this, and
                    // finishing now would throw away the person's only
                    // route to the thing they paid for.
                    continue
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
