import Foundation
import StoreKit

/// Buys a store product and hands the signed transaction onward.
///
/// Everything here is StoreKit's business and none of it is Onym's: the
/// coordinator does not know what a seat is, and the only thing it
/// produces is a platform-signed transaction for someone else to
/// validate. A client-side "paid" flag is never sufficient
/// (`WHITEPAPER.md` §17.3 step 6), so nothing here decides entitlement.
public actor StoreKitPurchaseCoordinator {
    public init() {}

    /// Products for the catalog's identifiers, for display.
    public func products(for identifiers: Set<String>) async throws -> [Product] {
        guard !identifiers.isEmpty else { return [] }
        return try await Product.products(for: identifiers)
    }

    /// Buy `product` and return the JWS StoreKit signed.
    ///
    /// The transaction is **not** finished here. Finishing tells the
    /// store the purchase is delivered, and it is not delivered until
    /// the broker has issued a credential — finishing early would leave
    /// someone charged with nothing to show, and no replay to recover
    /// from.
    public func purchase(_ product: Product) async throws -> (String, StoreKit.Transaction) {
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw BillingError.purchaseFailed(reason: String(describing: error))
        }
        switch result {
        case .success(let verification):
            return try Self.jws(from: verification)
        case .userCancelled:
            throw BillingError.purchaseFailed(reason: "cancelled")
        case .pending:
            // Ask-to-buy, or a payment the store is still processing.
            // Not a failure and not a purchase; `Transaction.updates`
            // delivers it if and when it resolves.
            throw BillingError.purchaseFailed(reason: "pending")
        @unknown default:
            throw BillingError.purchaseFailed(reason: "unknown")
        }
    }

    /// Current entitlement for a product, if the store has one — the
    /// restore-purchases and cross-device path.
    public func currentTransaction(for productId: String) async -> (String, StoreKit.Transaction)? {
        guard let verification = await StoreKit.Transaction.currentEntitlement(for: productId) else {
            return nil
        }
        return try? Self.jws(from: verification)
    }

    /// Ask the store to sync, for an explicit "Restore Purchases".
    public func sync() async throws {
        do {
            try await AppStore.sync()
        } catch {
            throw BillingError.purchaseFailed(reason: String(describing: error))
        }
    }

    /// Mark a transaction delivered. Called only once a credential
    /// exists.
    public func finish(_ transaction: StoreKit.Transaction) async {
        await transaction.finish()
    }

    private static func jws(
        from result: VerificationResult<StoreKit.Transaction>
    ) throws -> (String, StoreKit.Transaction) {
        switch result {
        case .verified(let transaction):
            return (result.jwsRepresentation, transaction)
        case .unverified(_, let error):
            // StoreKit could not verify its own signature. The broker
            // would refuse it too; failing here saves a round trip and
            // keeps an unverifiable receipt off the network.
            throw BillingError.purchaseFailed(reason: "unverified: \(error)")
        }
    }
}
