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

/// Sentences, not enum dumps.
///
/// These reach a person: a restore sweep puts a failed offer's reason
/// straight into the Device Backup screen, because the difference
/// between getting what you paid for and buying it twice is what that
/// row is for. `String(describing:)` on this enum produces
/// `brokerRejected(code: "invalid_transaction", message: Optional("…"))`,
/// which is a debugger's output rendered at somebody who is trying to
/// find out whether their subscription came across.
///
/// `brokerRejected` prefers the broker's own words. It is the one case
/// that carries a message written for a person, and a local guess at
/// what a refusal meant is worse than the refusal's own account of
/// itself.
extension BillingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedEntitlement:
            return "The purchase record could not be read."
        case .untrustedIssuer:
            return "The purchase was signed by someone this operator does not recognise."
        case .signatureInvalid:
            return "The purchase record's signature did not check out."
        case .audienceMismatch:
            return "That purchase belongs to a different operator."
        case .subjectMismatch:
            return "That purchase belongs to a different identity."
        case .expired:
            return "The subscription has expired."
        case .notYetValid(let notBefore):
            return "This purchase does not start until "
                + notBefore.formatted(date: .abbreviated, time: .shortened) + "."
        case .revoked:
            return "The purchase was refunded or reversed, so it no longer covers storage."
        case .envelopeUnreadable:
            return "The purchase record could not be opened on this device."
        case .offerNotSellable:
            return "This version of Onym cannot sell that operator's storage."
        case .purchaseFailed(let reason):
            // StoreKit's own words for its own refusal, and the two
            // that are not failures at all.
            switch reason {
            case "cancelled": return "The purchase was cancelled."
            case "pending": return "The purchase is waiting for approval."
            default: return "The App Store could not complete the purchase."
            }
        case .brokerRejected(let code, let message):
            // Its own account of itself beats our guess at what it
            // meant — and an unrecognised code is still worth naming,
            // because it is what support will ask for.
            if let message, !message.isEmpty { return message }
            return "The billing service refused this purchase (\(code))."
        case .brokerUnavailable:
            return "The billing service could not be reached."
        }
    }
}
