import Foundation

/// What the client sends a broker, and what comes back.
///
/// The store-signed transaction is the only platform-derived value that
/// ever leaves the device, it goes to the broker and nowhere else, and no
/// Onym identity travels with it (`WHITEPAPER.md` §17.8).
public struct SeatEntitlementRequest: Sendable, Equatable {
    public let offerId: String
    /// `onym:component:<id>` of the seat being bought.
    public let audience: String
    /// `onym:seat-key:<hex>` this entitlement should be bound to.
    public let subject: String
    /// The X25519 key the broker seals its answer to.
    public let sealTo: Data
    /// StoreKit 2's `VerificationResult.jwsRepresentation`.
    public let signedTransaction: String

    public init(
        offerId: String,
        audience: String,
        subject: String,
        sealTo: Data,
        signedTransaction: String
    ) {
        self.offerId = offerId
        self.audience = audience
        self.subject = subject
        self.sealTo = sealTo
        self.signedTransaction = signedTransaction
    }
}

/// The billing broker's client-facing surface.
///
/// Deliberately small. The broker validates purchases with the platform
/// and issues credentials; it is not consulted per connection, and there
/// is no per-entitlement status call — one would let the broker observe
/// every seat-to-holder session, which is exactly what §17.8 forbids.
/// Revocation arrives as a signed epoch document instead.
public protocol BillingBrokerClient: Sendable {
    /// Submit a purchase and receive a sealed entitlement.
    func issueEntitlement(_ request: SeatEntitlementRequest) async throws -> Data

    /// Refresh a subscription's credential, or rebind it to this
    /// device's seat key after a restore.
    func refreshEntitlement(_ request: SeatEntitlementRequest) async throws -> Data

    /// The current revocation epoch: a signed list of entitlement ids
    /// revoked and not yet expired. Public, unauthenticated, cacheable —
    /// fetching it tells the broker only that someone asked.
    func revocationEpoch() async throws -> RevocationEpoch
}

/// A broker-signed list of revoked entitlements.
public struct RevocationEpoch: Sendable, Equatable {
    public let epoch: Int
    public let publishedAt: Date
    public let revoked: Set<String>
    public let rawBytes: Data
    public let signature: Data

    public init(
        epoch: Int,
        publishedAt: Date,
        revoked: Set<String>,
        rawBytes: Data,
        signature: Data
    ) {
        self.epoch = epoch
        self.publishedAt = publishedAt
        self.revoked = revoked
        self.rawBytes = rawBytes
        self.signature = signature
    }
}
