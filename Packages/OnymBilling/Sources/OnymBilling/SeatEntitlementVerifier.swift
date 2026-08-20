import CryptoKit
import Foundation
import OnymFoundation

/// Checks an entitlement before anything treats it as one.
///
/// Every check here answers a question a caller would otherwise have to
/// remember to ask, and the order is deliberate: the signature is
/// verified before any field is believed, because an unsigned document's
/// `audience` is not evidence of anything.
public struct SeatEntitlementVerifier: Sendable {
    /// Issuer key references the operator names in its signed manifest.
    ///
    /// Pinned from there and nowhere else. Taking them from the
    /// entitlement would let a document nominate its own authority,
    /// which is not a check.
    public let trustedIssuers: [String]
    public let componentId: String
    /// The holder key this device signs that seat's requests with.
    public let subject: String

    public init(trustedIssuers: [String], componentId: String, subject: String) {
        self.trustedIssuers = trustedIssuers
        self.componentId = componentId
        self.subject = subject
    }

    /// Verify, or throw the first reason it is not usable.
    ///
    /// `revokedIds` comes from the broker's signed revocation epoch. It
    /// is passed in rather than fetched here so a caller can decide what
    /// a stale epoch means — an operator keeps serving on the last good
    /// one rather than refusing everyone during a broker outage, and
    /// this type should not quietly make that policy.
    public func verify(
        _ entitlement: SeatEntitlement,
        now: Date = Date(),
        revokedIds: Set<String> = []
    ) throws {
        guard trustedIssuers.contains(entitlement.issuer) else {
            throw BillingError.untrustedIssuer(issuer: entitlement.issuer)
        }
        guard
            let keyBytes = BillingFormat.publicKeyBytes(
                from: entitlement.issuer, prefix: BillingFormat.keyPrefix),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else {
            throw BillingError.untrustedIssuer(issuer: entitlement.issuer)
        }
        // The one canonicalization in this codebase: UTF-8 byte-order
        // keys, floats refused, one escaping set. The broker and the
        // operator run the same rules, and agreeing on bytes is the
        // entire point.
        let signingBytes = try ServiceManifestCanonical.signingBytes(
            of: entitlement.rawBytes,
            omitting: ["signature"]
        )
        guard key.isValidSignature(entitlement.signature, for: signingBytes) else {
            throw BillingError.signatureInvalid
        }

        guard entitlement.audience == componentId else {
            throw BillingError.audienceMismatch(
                expected: componentId, found: entitlement.audience)
        }
        guard entitlement.subject == subject else {
            throw BillingError.subjectMismatch
        }
        guard now >= entitlement.notBefore else {
            throw BillingError.notYetValid(notBefore: entitlement.notBefore)
        }
        guard now < entitlement.expiresAt else {
            throw BillingError.expired(expiresAt: entitlement.expiresAt)
        }
        guard !revokedIds.contains(entitlement.entitlementId) else {
            throw BillingError.revoked(entitlementId: entitlement.entitlementId)
        }
    }
}
