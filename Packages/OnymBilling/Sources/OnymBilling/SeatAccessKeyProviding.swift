import CryptoKit
import Foundation

/// The seat-scoped keys a purchase is bound to.
///
/// `OnymBilling` does not derive these — they belong to whichever seat is
/// being bought, and the derivation lives with that seat's key ladder.
/// The composition root supplies them, which also keeps this package
/// free of any dependency on identity.
public protocol SeatAccessKeyProviding: Sendable {
    /// `onym:seat-key:<64 lowercase hex>` for `componentId`. This is the
    /// entitlement's `subject`, byte for byte the value that seat's
    /// requests are signed with.
    func seatSubject(componentId: String) async throws -> String

    /// The X25519 private key a broker seals its answer to. Never
    /// leaves the device; only its public half is sent.
    func seatAgreementKey(componentId: String) async throws -> Curve25519.KeyAgreement.PrivateKey
}
