import CryptoKit
import Foundation
import OnymFoundation
import XCTest
@testable import OnymBilling

/// The credential path. Almost every test here asserts a refusal — a
/// credential that cannot be verified is not a credential, and the
/// interesting question is which ways of being wrong get caught.
final class BillingTests: XCTestCase {
    private let issuerSeed = Data(repeating: 0x21, count: 32)
    private let componentId = "onym:component:backup-op"

    private var issuerKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: issuerSeed)
    }

    private var issuerReference: String {
        "onym:key:" + issuerKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    private func subject(_ byte: UInt8 = 0x33) -> String {
        "onym:seat-key:" + String(repeating: String(format: "%02x", byte), count: 32)
    }

    /// Build a signed entitlement the way a conforming broker would:
    /// canonical bytes, detached Ed25519, signature folded back in.
    private func makeEntitlement(
        issuer: String? = nil,
        audience: String? = nil,
        subject subjectValue: String? = nil,
        offerId: String = "backup-monthly-v1",
        entitlementId: String = "e-1",
        notBefore: Date = Date().addingTimeInterval(-60),
        expiresAt: Date = Date().addingTimeInterval(3600),
        signWith: Curve25519.Signing.PrivateKey? = nil
    ) throws -> Data {
        var document: [String: Any] = [
            "version": 1,
            "type": "SeatEntitlement",
            "issuer": issuer ?? issuerReference,
            "audience": audience ?? componentId,
            "subject": subjectValue ?? subject(),
            "offerId": offerId,
            "entitlementId": entitlementId,
            "notBefore": BillingFormat.string(fromDate: notBefore),
            "expiresAt": BillingFormat.string(fromDate: expiresAt),
        ]
        let unsigned = try JSONSerialization.data(withJSONObject: document)
        let signingBytes = try ServiceManifestCanonical.signingBytes(of: unsigned, omitting: ["signature"])
        let signature = try (signWith ?? issuerKey).signature(for: signingBytes)
        document["signature"] = signature.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: document)
    }

    private func verifier(subject subjectValue: String? = nil) -> SeatEntitlementVerifier {
        SeatEntitlementVerifier(
            trustedIssuers: [issuerReference],
            componentId: componentId,
            subject: subjectValue ?? subject())
    }

    func testValidEntitlementVerifies() throws {
        let entitlement = try SeatEntitlement.decode(raw: try makeEntitlement())
        XCTAssertNoThrow(try verifier().verify(entitlement))
        XCTAssertTrue(entitlement.isCurrent())
    }

    /// A document must not be able to nominate its own authority.
    func testForeignIssuerIsRefused() throws {
        let stranger = Curve25519.Signing.PrivateKey()
        let reference = "onym:key:" + stranger.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        let entitlement = try SeatEntitlement.decode(
            raw: try makeEntitlement(issuer: reference, signWith: stranger))
        XCTAssertThrowsError(try verifier().verify(entitlement)) { error in
            guard case BillingError.untrustedIssuer = error else {
                return XCTFail("expected untrustedIssuer, got \(error)")
            }
        }
    }

    /// A field changed after signing must fail the signature, not the
    /// field check — otherwise the signature is decorative.
    func testMutatedFieldFailsTheSignature() throws {
        var object = try JSONSerialization.jsonObject(with: try makeEntitlement()) as! [String: Any]
        object["offerId"] = "backup-yearly-v1"
        let tampered = try SeatEntitlement.decode(
            raw: try JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try verifier().verify(tampered)) { error in
            XCTAssertEqual(error as? BillingError, .signatureInvalid)
        }
    }

    /// One operator never receives another's credential.
    func testWrongAudienceIsRefused() throws {
        let entitlement = try SeatEntitlement.decode(
            raw: try makeEntitlement(audience: "onym:component:someone-else"))
        XCTAssertThrowsError(try verifier().verify(entitlement)) { error in
            guard case BillingError.audienceMismatch = error else {
                return XCTFail("expected audienceMismatch, got \(error)")
            }
        }
    }

    /// This is what stops a captured credential being useful to anyone
    /// else: it is bound to a key only this device holds.
    func testWrongSubjectIsRefused() throws {
        let entitlement = try SeatEntitlement.decode(
            raw: try makeEntitlement(subject: subject(0x44)))
        XCTAssertThrowsError(try verifier().verify(entitlement)) { error in
            XCTAssertEqual(error as? BillingError, .subjectMismatch)
        }
    }

    func testExpiredAndNotYetValidAreRefused() throws {
        let expired = try SeatEntitlement.decode(
            raw: try makeEntitlement(
                notBefore: Date().addingTimeInterval(-7200),
                expiresAt: Date().addingTimeInterval(-3600)))
        XCTAssertThrowsError(try verifier().verify(expired)) { error in
            guard case BillingError.expired = error else {
                return XCTFail("expected expired, got \(error)")
            }
        }

        let future = try SeatEntitlement.decode(
            raw: try makeEntitlement(
                notBefore: Date().addingTimeInterval(3600),
                expiresAt: Date().addingTimeInterval(7200)))
        XCTAssertThrowsError(try verifier().verify(future)) { error in
            guard case BillingError.notYetValid = error else {
                return XCTFail("expected notYetValid, got \(error)")
            }
        }
    }

    /// A refund lands here: the credential is still signed and still in
    /// date, and must stop working anyway.
    func testRevokedIdIsRefused() throws {
        let entitlement = try SeatEntitlement.decode(
            raw: try makeEntitlement(entitlementId: "e-refunded"))
        XCTAssertThrowsError(
            try verifier().verify(entitlement, revokedIds: ["e-refunded"])
        ) { error in
            guard case BillingError.revoked = error else {
                return XCTFail("expected revoked, got \(error)")
            }
        }
    }

    /// The seat envelope must not accept an invitation envelope. Sharing
    /// a suite would make the two interchangeable at the crypto layer.
    func testInvitationSchemeIsRefusedBySeatEnvelope() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let wire: [String: Any] = [
            "version": 1,
            "scheme": "x25519-aes-256-gcm-v1",
            "ephemeral_public_key": Data(repeating: 1, count: 32).base64EncodedString(),
            "nonce": Data(repeating: 2, count: 12).base64EncodedString(),
            "ciphertext": Data(repeating: 3, count: 16).base64EncodedString(),
            "authentication_tag": Data(repeating: 4, count: 16).base64EncodedString(),
        ]
        let bytes = try JSONSerialization.data(withJSONObject: wire)
        XCTAssertThrowsError(
            try SeatSealedEnvelope.open(envelopeBytes: bytes, recipient: recipient)
        ) { error in
            XCTAssertEqual(error as? BillingError, .envelopeUnreadable)
        }
    }

    /// A free offer resolves with no store, no network, and no
    /// credential — a self-hosted operator charging nothing is a
    /// first-class case.
    func testFreeOfferStillResolvesWithoutAnyCredential() async throws {
        let provider = StoreKitEntitlementProvider(
            free: FreeTierEntitlementProvider(offerLookup: { offerId, _ in
                offerId == "free-v1" ? ServiceOffer(offerId: "free-v1", model: "free") : nil
            }),
            catalog: ChannelOfferCatalog(offers: []),
            store: MemoryEntitlementStore(),
            keys: StubKeys(subject: subject()),
            trustedIssuers: { _ in [] })

        let granted = await provider.entitlement(for: "free-v1", component: componentId)
        XCTAssertEqual(granted?.offerId, "free-v1")
        XCTAssertNil(granted?.expiresAt)
    }

    /// An offer with no store product cannot be sold through this app.
    /// A manifest cannot mint a store product at runtime.
    func testPaidOfferWithoutACatalogEntryIsNotEntitled() async throws {
        let provider = StoreKitEntitlementProvider(
            free: FreeTierEntitlementProvider(offerLookup: { _, _ in
                ServiceOffer(offerId: "backup-monthly-v1", model: "subscription")
            }),
            catalog: ChannelOfferCatalog(offers: []),
            store: MemoryEntitlementStore(raw: [try makeEntitlement()]),
            keys: StubKeys(subject: subject()),
            trustedIssuers: { _ in [self.issuerReference] })

        let granted = await provider.entitlement(
            for: "backup-monthly-v1", component: componentId)
        XCTAssertNil(granted)
    }

    /// With a catalog entry and a valid stored credential, the offer
    /// becomes selectable — and carries its expiry.
    func testStoredCredentialGrantsThePaidOffer() async throws {
        let raw = try makeEntitlement()
        let provider = StoreKitEntitlementProvider(
            free: FreeTierEntitlementProvider(offerLookup: { _, _ in
                ServiceOffer(offerId: "backup-monthly-v1", model: "subscription")
            }),
            catalog: ChannelOfferCatalog(offers: [
                ChannelOffer(
                    channelOfferId: "sha256:x", componentId: componentId,
                    offerId: "backup-monthly-v1", productId: "app.onym.backup.monthly",
                    productType: "auto-renewable-subscription",
                    operatorShareBps: 7000, frontendCommissionBps: 3000)
            ]),
            store: MemoryEntitlementStore(raw: [raw]),
            keys: StubKeys(subject: subject()),
            trustedIssuers: { _ in [self.issuerReference] })

        let granted = await provider.entitlement(
            for: "backup-monthly-v1", component: componentId)
        XCTAssertEqual(granted?.componentId, componentId)
        XCTAssertNotNil(granted?.expiresAt)
    }

    /// A revoked credential stops granting, even though it is signed and
    /// in date.
    func testRevokedCredentialStopsGrantingTheOffer() async throws {
        let raw = try makeEntitlement(entitlementId: "e-refunded")
        let provider = StoreKitEntitlementProvider(
            free: FreeTierEntitlementProvider(offerLookup: { _, _ in
                ServiceOffer(offerId: "backup-monthly-v1", model: "subscription")
            }),
            catalog: ChannelOfferCatalog(offers: [
                ChannelOffer(
                    channelOfferId: "sha256:x", componentId: componentId,
                    offerId: "backup-monthly-v1", productId: "app.onym.backup.monthly",
                    productType: "auto-renewable-subscription",
                    operatorShareBps: 7000, frontendCommissionBps: 3000)
            ]),
            store: MemoryEntitlementStore(raw: [raw]),
            keys: StubKeys(subject: subject()),
            trustedIssuers: { _ in [self.issuerReference] },
            revokedIds: { ["e-refunded"] })

        let granted = await provider.entitlement(
            for: "backup-monthly-v1", component: componentId)
        XCTAssertNil(granted)
    }
}

private struct StubKeys: SeatAccessKeyProviding {
    let subject: String
    let agreement = Curve25519.KeyAgreement.PrivateKey()

    func seatSubject(componentId: String) async throws -> String { subject }
    func seatAgreementKey(componentId: String) async throws -> Curve25519.KeyAgreement.PrivateKey {
        agreement
    }
}

private final class MemoryEntitlementStore: SeatEntitlementStoring, @unchecked Sendable {
    private var raw: [Data]
    private let lock = NSLock()

    init(raw: [Data] = []) { self.raw = raw }
    func load() throws -> [Data] { lock.withLock { raw } }
    func save(_ rawEntitlements: [Data]) throws { lock.withLock { raw = rawEntitlements } }
}
