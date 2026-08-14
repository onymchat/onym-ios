import Foundation
import CryptoKit
import XCTest
@testable import OnymFoundation

final class ServiceManifestReviewerTests: XCTestCase {
    private let reviewer = ServiceManifestReviewer()

    // MARK: - Happy path

    func testReviewAcceptsSelfSignedManifestAndPreservesExactBytes() throws {
        let (raw, key) = try ManifestFactory.signedSample()
        let reviewed = try reviewer.review(raw: raw, now: ManifestFactory.now)
        let manifest = reviewed.signedManifest

        XCTAssertEqual(manifest.componentId, "onym:component:sample-notary")
        XCTAssertEqual(manifest.seat, "notary")
        XCTAssertEqual(manifest.operatorPublicKeyHex, ManifestFactory.operatorKeyHex(key))
        XCTAssertEqual(manifest.validUntil, ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        // Same-bytes guarantee: the token carries the exact bytes that
        // were verified, and the hash is over those bytes.
        XCTAssertEqual(manifest.rawBytes, raw)
        XCTAssertEqual(manifest.manifestHash, ServiceManifestFormat.sha256Digest(of: raw))
        XCTAssertTrue(manifest.manifestHash.hasPrefix("sha256:"))
    }

    func testReviewToleratesUnknownFields() throws {
        // Destination seats own their schemas — a field this layer has
        // never heard of must not fail the spine parse or the signature.
        let (raw, _) = try ManifestFactory.signedSample { object in
            object["someFutureField"] = ["nested": ["deep": true]]
            object["capabilities"] = ["a", "b"]
        }
        XCTAssertNoThrow(try reviewer.review(raw: raw, now: ManifestFactory.now))
    }

    func testReviewAcceptsManifestWithoutValidUntil() throws {
        let (raw, _) = try ManifestFactory.signedSample { object in
            object.removeValue(forKey: "validUntil")
        }
        let reviewed = try reviewer.review(raw: raw, now: ManifestFactory.now)
        XCTAssertNil(reviewed.signedManifest.validUntil)
    }

    // MARK: - Signature

    func testTamperedByteFailsSignature() throws {
        let (raw, _) = try ManifestFactory.signedSample()
        // Same-length substitution keeps the JSON valid so the failure
        // is unambiguously the signature, not the parse.
        var text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("Sample Notary"))
        text = text.replacingOccurrences(of: "Sample Notary", with: "Sample Notarz")
        let tampered = Data(text.utf8)

        XCTAssertThrowsError(try reviewer.review(raw: tampered, now: ManifestFactory.now)) { error in
            guard case ServiceManifestError.signatureInvalid = error else {
                return XCTFail("expected signatureInvalid, got \(error)")
            }
        }
    }

    func testMissingSignatureIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        var object = ManifestFactory.sampleObject(operatorKeyHex: ManifestFactory.operatorKeyHex(key))
        object.removeValue(forKey: "signature")
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])

        XCTAssertThrowsError(try reviewer.review(raw: raw, now: ManifestFactory.now)) { error in
            guard case ServiceManifestError.signatureInvalid = error else {
                return XCTFail("expected signatureInvalid, got \(error)")
            }
        }
    }

    func testSignatureByWrongKeyIsRejected() throws {
        // Signed with one key, `operator` names another.
        let signingKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let object = ManifestFactory.sampleObject(operatorKeyHex: ManifestFactory.operatorKeyHex(otherKey))
        let raw = try ManifestFactory.signedBytes(object: object, key: signingKey)

        XCTAssertThrowsError(try reviewer.review(raw: raw, now: ManifestFactory.now)) { error in
            guard case ServiceManifestError.signatureInvalid = error else {
                return XCTFail("expected signatureInvalid, got \(error)")
            }
        }
    }

    // MARK: - Digest pin

    func testMatchingExpectedDigestPasses() throws {
        let (raw, _) = try ManifestFactory.signedSample()
        let digest = ServiceManifestFormat.sha256Digest(of: raw)
        XCTAssertNoThrow(try reviewer.review(raw: raw, expectedDigest: digest, now: ManifestFactory.now))
    }

    func testDigestMismatchIsRejected() throws {
        let (raw, _) = try ManifestFactory.signedSample()
        let wrong = "sha256:" + String(repeating: "ab", count: 32)
        XCTAssertThrowsError(
            try reviewer.review(raw: raw, expectedDigest: wrong, now: ManifestFactory.now)
        ) { error in
            guard case let ServiceManifestError.digestMismatch(expected, actual) = error else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
            XCTAssertEqual(expected, wrong)
            XCTAssertEqual(actual, ServiceManifestFormat.sha256Digest(of: raw))
        }
    }

    func testMalformedExpectedDigestIsRejectedAsPinMalformedNotMismatch() throws {
        // "caller passed garbage" and "bytes were swapped" are
        // different failures; conflating them makes catalog bugs look
        // like attacks. The specific case is asserted, not just "throws".
        let (raw, _) = try ManifestFactory.signedSample()
        XCTAssertThrowsError(
            try reviewer.review(raw: raw, expectedDigest: "not-a-digest", now: ManifestFactory.now)
        ) { error in
            guard case let ServiceManifestError.digestPinMalformed(value) = error else {
                return XCTFail("expected digestPinMalformed, got \(error)")
            }
            XCTAssertEqual(value, "not-a-digest")
        }
    }

    func testUppercaseExpectedDigestIsNormalizedAndAccepted() throws {
        // Digests copied out of catalogs or chat come uppercased often
        // enough; the same pin must not read as a mismatch.
        let (raw, _) = try ManifestFactory.signedSample()
        let digest = ServiceManifestFormat.sha256Digest(of: raw)
        let uppercased = "sha256:" + digest.dropFirst("sha256:".count).uppercased()
        XCTAssertNoThrow(
            try reviewer.review(raw: raw, expectedDigest: uppercased, now: ManifestFactory.now)
        )
    }

    // MARK: - Expiry

    func testExpiredManifestIsRejected() throws {
        let (raw, _) = try ManifestFactory.signedSample { object in
            object["validUntil"] = "2026-01-01T00:00:00Z"
        }
        XCTAssertThrowsError(try reviewer.review(raw: raw, now: ManifestFactory.now)) { error in
            guard case ServiceManifestError.expired = error else {
                return XCTFail("expected expired, got \(error)")
            }
        }
    }

    // MARK: - Spine validation

    func testMalformedComponentIdIsRejected() throws {
        let (raw, _) = try ManifestFactory.signedSample { object in
            object["componentId"] = "not-a-component-id"
        }
        XCTAssertThrowsError(try reviewer.review(raw: raw, now: ManifestFactory.now)) { error in
            guard case ServiceManifestError.manifestInvalid = error else {
                return XCTFail("expected manifestInvalid, got \(error)")
            }
        }
    }

    func testMalformedOperatorKeyIsRejected() throws {
        let (raw, _) = try ManifestFactory.signedSample { object in
            object["operator"] = "onym:key:ZZZZ"
        }
        XCTAssertThrowsError(try reviewer.review(raw: raw, now: ManifestFactory.now)) { error in
            guard case ServiceManifestError.manifestInvalid = error else {
                return XCTFail("expected manifestInvalid, got \(error)")
            }
        }
    }

    func testEmptySeatIsRejected() throws {
        let (raw, _) = try ManifestFactory.signedSample { object in
            object["seat"] = ""
        }
        XCTAssertThrowsError(try reviewer.review(raw: raw, now: ManifestFactory.now))
    }

    func testNonJSONIsRejected() {
        XCTAssertThrowsError(try reviewer.review(raw: Data("not json".utf8), now: ManifestFactory.now)) { error in
            guard case ServiceManifestError.manifestInvalid = error else {
                return XCTFail("expected manifestInvalid, got \(error)")
            }
        }
    }

    // MARK: - Offers (lossy)

    func testOffersDecodeLossily() throws {
        let (raw, _) = try ManifestFactory.signedSample { object in
            object["offers"] = [
                ["offerId": "free-tier", "model": "free"],
                ["offerId": "missing-model"],           // skipped
                "not even an object",                   // skipped
                ["offerId": "pro", "model": "subscription", "period": "monthly"],
                ["offerId": "boost", "model": "some-future-model"],
            ]
        }
        let offers = try reviewer.review(raw: raw, now: ManifestFactory.now).signedManifest.offers
        XCTAssertEqual(offers.map(\.offerId), ["free-tier", "pro", "boost"])
        XCTAssertTrue(offers[0].isFree)
        XCTAssertFalse(offers[1].isFree)
        XCTAssertEqual(offers[1].period, "monthly")
        // Unknown models are preserved verbatim and gate as not-free.
        XCTAssertEqual(offers[2].model, "some-future-model")
        XCTAssertFalse(offers[2].isFree)
    }

    // MARK: - Format helpers

    func testBase64DecodeAcceptsUnpaddedInput() {
        // The spec accepts padded or unpadded base64 signatures; the
        // unpadded branch strips down to the manual re-pad path.
        let padded = ServiceManifestFormat.decodeBase64AcceptingUnpadded("aGVsbG8=")
        let unpadded = ServiceManifestFormat.decodeBase64AcceptingUnpadded("aGVsbG8")
        XCTAssertEqual(padded, Data("hello".utf8))
        XCTAssertEqual(unpadded, Data("hello".utf8))
        // Not base64 at all — both branches refuse.
        XCTAssertNil(ServiceManifestFormat.decodeBase64AcceptingUnpadded("!!!"))
    }

    func testAbsentOffersDecodeAsEmpty() throws {
        let (raw, _) = try ManifestFactory.signedSample { object in
            object.removeValue(forKey: "offers")
        }
        let reviewed = try reviewer.review(raw: raw, now: ManifestFactory.now)
        XCTAssertEqual(reviewed.signedManifest.offers, [])
    }

    func testOfferServiceObjectIsCarriedOpaquely() throws {
        let reviewed = try ManifestFactory.reviewedSample()
        let free = reviewed.signedManifest.offers.first { $0.offerId == "free-tier" }
        let serviceData = try XCTUnwrap(free?.serviceData)
        let decoded = try JSONSerialization.jsonObject(with: serviceData) as? [String: Any]
        XCTAssertEqual(decoded?["quota"] as? Int, 100)
    }
}
