import CryptoKit
import Foundation
import XCTest
@testable import OnymBackup
@testable import OnymFoundation

/// The two signatures on a terms document cover **different bytes**, and
/// treating them as interchangeable rejects an operator that is doing
/// everything right.
///
/// This is not hypothetical. `verifyTermsSignature` checked the detached
/// `.sig` against the canonical message, which cannot verify for any
/// correct operator: every enrolment against the deployed
/// `backup.onym.app` failed with "the operator's terms could not be
/// verified" while the served document was valid on both counts.
final class BackupTermsSignatureTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()

    /// A terms document signed the way the profile says: the embedded
    /// `signature` over canonical bytes with `termsId` and `signature`
    /// removed, and a detached sibling over the exact served bytes.
    private func signedTerms() throws -> (raw: Data, detached: Data) {
        let body: [String: Any] = [
            "termsVersion": 1,
            "operator": "onym:key:" + key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
            "retention": [
                "class": "best-effort", "maximumRetentionPeriod": "until-erased",
                "snapshotsRetained": "2", "expiryBehavior": "notify-then-erase",
            ],
            "erasure": [
                "acknowledgementDeadline": "PT1H", "completionDeadline": "P7D",
                "scope": "the primary copy", "excluded": "copies held by other participants",
            ],
            "jurisdictions": ["EE"],
            "subProcessors": [],
            "lawfulAccess": [
                "disclosureWhatIsProduced": "sealed-bytes-and-declared-metadata-only",
                "notifyHolderWhenPermitted": true,
            ],
            "breachDisclosure": ["holderNotice": "P3D"],
            "export": ["format": "tar", "availableWhileUnpaid": true],
            "shutdownNotice": "P90D",
            "endOfPayment": [
                "notice": "P14D", "grace": "P30D",
                "duringGrace": ["download", "export", "erase"], "afterGrace": "erase",
            ],
            "metadataRetention": [
                "accessLogs": "none", "sizeAndTiming": "while the snapshot is retained",
                "holderIdentifiers": "while any snapshot is held", "operationOutcomes": "PT6H",
                "erasureReceipts": "P365D", "entitlementRecords": "PT15M",
            ],
        ]
        let unsigned = try JSONSerialization.data(withJSONObject: body)
        let canonical = try ServiceManifestCanonical.signingBytes(
            of: unsigned, omitting: ["termsId", "signature"])
        let embedded = try key.signature(for: canonical)

        var signed = body
        signed["termsId"] = "sha256:" + SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }.joined()
        signed["signature"] = embedded.base64EncodedString()
        let raw = try JSONSerialization.data(withJSONObject: signed)
        // The detached sibling signs the served bytes verbatim — which
        // is why it is not the same signature as the embedded one.
        return (raw, try key.signature(for: raw))
    }

    /// The regression. Both signatures present and correct, and the
    /// document must be accepted.
    func testACorrectlySignedTermsDocumentVerifies() throws {
        let (raw, detached) = try signedTerms()
        let terms = try BackupTerms.decode(raw: raw, detachedSignature: detached)

        let canonical = try ServiceManifestCanonical.signingBytes(
            of: raw, omitting: ["termsId", "signature"])
        let embedded = try XCTUnwrap(terms.embeddedSignature)

        XCTAssertTrue(
            key.publicKey.isValidSignature(embedded, for: canonical),
            "the embedded signature must verify over canonical bytes")
        XCTAssertTrue(
            key.publicKey.isValidSignature(detached, for: raw),
            "the detached signature must verify over the exact served bytes")
    }

    /// The bug itself, asserted so nobody re-introduces it by deciding
    /// the two signatures are the same thing.
    func testTheTwoSignaturesDoNotCoverTheSameBytes() throws {
        let (raw, detached) = try signedTerms()
        let canonical = try ServiceManifestCanonical.signingBytes(
            of: raw, omitting: ["termsId", "signature"])

        XCTAssertNotEqual(raw, canonical, "the fixture no longer distinguishes the two messages")
        XCTAssertFalse(
            key.publicKey.isValidSignature(detached, for: canonical),
            "the detached signature must NOT verify over canonical bytes — checking it that way is what rejected every honest operator")
    }

    /// `decode` reads the embedded signature from the document rather
    /// than taking it from the caller, so the two can never be swapped
    /// by a call site again.
    func testDecodeReadsTheEmbeddedSignatureFromTheDocument() throws {
        let (raw, detached) = try signedTerms()
        let terms = try BackupTerms.decode(raw: raw, detachedSignature: detached)
        XCTAssertNotEqual(terms.embeddedSignature, detached)
        XCTAssertEqual(terms.detachedSignature, detached)
    }

    /// A document with no embedded signature is not terms, however
    /// convincing its detached sibling looks.
    func testAnUnsignedDocumentIsRefused() throws {
        let (raw, detached) = try signedTerms()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw) as? [String: Any])
        object.removeValue(forKey: "signature")
        let unsigned = try JSONSerialization.data(withJSONObject: object)
        let terms = try BackupTerms.decode(raw: unsigned, detachedSignature: detached)
        XCTAssertNil(terms.embeddedSignature)
    }
}
