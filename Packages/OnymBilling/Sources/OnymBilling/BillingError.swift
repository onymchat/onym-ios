import Foundation

/// What can go wrong between a purchase and a usable credential.
public enum BillingError: Error, Equatable, Sendable {
    /// The document is not a `SeatEntitlement` we can read at all.
    case malformedEntitlement
    /// Signed by a key the operator does not name as an issuer.
    ///
    /// The issuer set is pinned from the operator's signed manifest —
    /// never from the entitlement, which would let a document vouch for
    /// itself.
    case untrustedIssuer(issuer: String)
    case signatureInvalid
    /// Issued for a different seat. One operator never receives
    /// another's credential.
    case audienceMismatch(expected: String, found: String)
    /// Issued to a different holder key. This is what stops a captured
    /// credential being useful to anyone else.
    case subjectMismatch
    case expired(expiresAt: Date)
    case notYetValid(notBefore: Date)
    /// Named in the broker's revocation epoch — refunded, or the
    /// purchase was reversed.
    case revoked(entitlementId: String)
    /// The sealed envelope did not open: wrong key, wrong scheme, or
    /// tampered bytes.
    case envelopeUnreadable
    /// This offer has no store product in the catalog, so it cannot be
    /// sold through this app. Not an error in the operator's manifest —
    /// a store product is a business arrangement, not something a
    /// manifest can mint at runtime.
    case offerNotSellable(offerId: String)
    /// StoreKit refused, or the person cancelled.
    case purchaseFailed(reason: String)
    /// The broker rejected the submission, with its own code preserved.
    case brokerRejected(code: String, message: String?)
    case brokerUnavailable
}
