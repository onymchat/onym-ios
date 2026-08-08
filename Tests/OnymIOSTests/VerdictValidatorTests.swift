import XCTest
import CryptoKit
@testable import OnymModeration
@testable import OnymFoundation

/// The §5.6 fixture table: mechanical verdict shape validation. Every
/// case here is a constraint the spec names; a validator change that
/// breaks one of these is a conformance regression, not a refactor.
final class VerdictValidatorTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let validator = VerdictValidator()

    /// The key the fixture manifest names as its `operator`. Verdict
    /// signatures verify against it, so enforce-on tests sign with the
    /// matching private key.
    private static let operatorKey = Curve25519.Signing.PrivateKey()

    /// Literal manifest bytes, exactly as production sees them (a
    /// fetched document), so the pinned hash is stable by construction
    /// rather than by encoder configuration.
    private static func manifestBytes(operatorReference: String) -> Data {
        Data("""
        {
          "version": 1,
          "componentId": "onym:component:authority",
          "seat": "moderation",
          "operator": "\(operatorReference)",
          "moderationProfileId": "onym:moderation-profile:consent-bound-v1",
          "violationClasses": [
            {
              "classId": "csam",
              "definition": "hash:csam-def",
              "responseWindow": "P3D",
              "decisionDeadline": "P7D",
              "banTerm": "permanent",
              "appealWindow": "P30D",
              "appealEffect": "non-suspensive"
            },
            {
              "classId": "unsolicited-pornography",
              "definition": "hash:up-def",
              "responseWindow": "P7D",
              "decisionDeadline": "P14D",
              "banTerm": "P90D",
              "appealWindow": "P30D",
              "appealEffect": "suspensive"
            }
          ],
          "newHolderAppeal": "hash:new-holder",
          "appellate": "onym:component:appellate",
          "validUntil": "2030-01-01T00:00:00Z"
        }
        """.utf8)
    }

    private func signedManifest(bytes: Data) throws -> SignedManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return SignedManifest(
            manifest: try decoder.decode(AuthorityManifest.self, from: bytes),
            rawBytes: bytes
        )
    }

    /// `onym:key:<hex>` for raw key bytes — the form
    /// `AuthorityKey.rawBytes(fromReference:)` parses.
    private static func reference(for publicKey: Curve25519.Signing.PublicKey) -> String {
        AuthorityKey.referencePrefix
            + publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    private func fixtureManifest() throws -> SignedManifest {
        try signedManifest(
            bytes: Self.manifestBytes(operatorReference: Self.reference(for: Self.operatorKey.publicKey))
        )
    }

    /// Pinned to the fixture manifest's real hash — the validator
    /// requires the supplied manifest to be the consented one.
    private func fixtureMandate() -> ModerationMandate {
        ModerationMandate(
            user: "onym:key:user",
            interface: "onym:component:onym-ios",
            authority: "onym:component:authority",
            manifestHash: (try? fixtureManifest().manifestHash) ?? "",
            classes: ["csam", "unsolicited-pornography"],
            deviceBinding: "enrollment-1",
            acceptedAt: now.addingTimeInterval(-30 * 86_400),
            signatures: ["user-sig"]
        )
    }

    /// A shape-valid, executed (`executeAfter == decidedAt`, both in
    /// the past) non-suspensive ban against the permanent class.
    private func validBan(mandate: ModerationMandate) throws -> Verdict {
        let decidedAt = now.addingTimeInterval(-86_400)
        return Verdict(
            caseId: "case-1",
            authority: "onym:component:authority",
            mandateRef: try mandate.mandateHash(),
            accusedKeys: ["onym:key:user"],
            deviceBinding: "enrollment-1",
            classId: "csam",
            disposition: .ban,
            marks: Marks(caseOpen: false, banned: true),
            banExpires: nil,  // permanent class
            executeAfter: decidedAt,
            reasoning: "hash:findings",
            appealDeadline: now.addingTimeInterval(29 * 86_400),
            decidedAt: decidedAt,
            signature: "unsigned-fixture",
            isFinal: false
        )
    }

    private func copy(
        _ verdict: Verdict,
        classId: String? = nil,
        disposition: Verdict.Disposition? = nil,
        marks: Marks? = nil,
        banExpires: Date?? = nil,
        executeAfter: Date?? = nil,
        reasoning: String? = nil,
        appealDeadline: Date?? = nil,
        mandateRef: String? = nil,
        deviceBinding: String? = nil,
        isFinal: Bool? = nil
    ) -> Verdict {
        Verdict(
            caseId: verdict.caseId,
            authority: verdict.authority,
            mandateRef: mandateRef ?? verdict.mandateRef,
            accusedKeys: verdict.accusedKeys,
            deviceBinding: deviceBinding ?? verdict.deviceBinding,
            classId: classId ?? verdict.classId,
            disposition: disposition ?? verdict.disposition,
            marks: marks ?? verdict.marks,
            banExpires: banExpires ?? verdict.banExpires,
            executeAfter: executeAfter ?? verdict.executeAfter,
            reasoning: reasoning ?? verdict.reasoning,
            appealDeadline: appealDeadline ?? verdict.appealDeadline,
            decidedAt: verdict.decidedAt,
            signature: verdict.signature,
            isFinal: isFinal ?? verdict.isFinal
        )
    }

    private func validate(_ verdict: Verdict) throws -> VerdictValidator.Outcome {
        try validator.validate(
            verdict,
            mandate: fixtureMandate(),
            consented: try fixtureManifest(),
            now: now,
            enforceSignature: false
        )
    }

    // MARK: - Executable shapes

    func testValidNonSuspensiveBanExecutes() throws {
        XCTAssertEqual(try validate(try validBan(mandate: fixtureMandate())), .execute)
    }

    func testSuspensiveBanStoredUntilExecuteAfter() throws {
        // Suspensive class: executeAfter == appealDeadline, which is
        // still in the future → stored, not executed (early mark
        // writes are nonconforming).
        let appealDeadline = now.addingTimeInterval(29 * 86_400)
        let verdict = copy(
            try validBan(mandate: fixtureMandate()),
            classId: "unsolicited-pornography",
            banExpires: .some(now.addingTimeInterval(119 * 86_400)),
            executeAfter: .some(appealDeadline),
            appealDeadline: .some(appealDeadline)
        )
        XCTAssertEqual(try validate(verdict), .storeUntilExecuteAfter(appealDeadline))
    }

    func testValidOpenCaseAndDismissalExecute() throws {
        let base = try validBan(mandate: fixtureMandate())
        let openCase = copy(
            base,
            disposition: .openCase,
            marks: Marks(caseOpen: true, banned: false),
            banExpires: .some(nil),
            executeAfter: .some(nil),
            reasoning: "hash:intake",
            appealDeadline: .some(nil)
        )
        XCTAssertEqual(try validate(openCase), .execute)

        let dismissal = copy(
            base,
            disposition: .dismiss,
            marks: Marks(caseOpen: false, banned: false),
            executeAfter: .some(nil)
        )
        XCTAssertEqual(try validate(dismissal), .execute)
    }

    // MARK: - Mandate binding

    func testMandateRefMismatchIsNoMandate() throws {
        let verdict = copy(try validBan(mandate: fixtureMandate()), mandateRef: "deadbeef")
        XCTAssertThrowsError(try validate(verdict)) { error in
            XCTAssertEqual(error as? ModerationError, .noMandate)
        }
    }

    func testClassOutsideMandateRefused() throws {
        let verdict = copy(try validBan(mandate: fixtureMandate()), classId: "spam")
        XCTAssertThrowsError(try validate(verdict)) { error in
            XCTAssertEqual(error as? ModerationError, .classOutsideMandate("spam"))
        }
    }

    func testDeviceBindingOutsideMandateRefused() throws {
        let verdict = copy(try validBan(mandate: fixtureMandate()), deviceBinding: "other-device")
        XCTAssertThrowsError(try validate(verdict))
    }

    // MARK: - Ban shape

    func testBanWithInconsistentMarksRefused() throws {
        let verdict = copy(
            try validBan(mandate: fixtureMandate()),
            marks: Marks(caseOpen: true, banned: true)
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    func testBanMissingExpiryOnNonPermanentClassRefused() throws {
        let appealDeadline = now.addingTimeInterval(29 * 86_400)
        let verdict = copy(
            try validBan(mandate: fixtureMandate()),
            classId: "unsolicited-pornography",
            banExpires: .some(nil),
            executeAfter: .some(appealDeadline),
            appealDeadline: .some(appealDeadline)
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    func testBanMissingExecuteAfterRefused() throws {
        let verdict = copy(try validBan(mandate: fixtureMandate()), executeAfter: .some(nil))
        XCTAssertThrowsError(try validate(verdict))
    }

    func testNonSuspensiveExecuteAfterMustEqualDecidedAt() throws {
        let base = try validBan(mandate: fixtureMandate())
        let verdict = copy(base, executeAfter: .some(base.decidedAt.addingTimeInterval(60)))
        XCTAssertThrowsError(try validate(verdict))
    }

    func testSuspensiveExecuteAfterMustEqualAppealDeadline() throws {
        let base = try validBan(mandate: fixtureMandate())
        let verdict = copy(
            base,
            classId: "unsolicited-pornography",
            banExpires: .some(now.addingTimeInterval(119 * 86_400)),
            executeAfter: .some(base.decidedAt)  // ≠ appealDeadline
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    // MARK: - Open-case / dismissal shape

    func testOpenCaseCarryingSanctionFieldsRefused() throws {
        let base = try validBan(mandate: fixtureMandate())
        let verdict = copy(
            base,
            disposition: .openCase,
            marks: Marks(caseOpen: true, banned: false),
            banExpires: .some(now.addingTimeInterval(90 * 86_400)),
            executeAfter: .some(nil),
            appealDeadline: .some(nil)
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    func testEmptyReasoningRefused() throws {
        let verdict = copy(try validBan(mandate: fixtureMandate()), reasoning: "")
        XCTAssertThrowsError(try validate(verdict))
    }

    func testDismissalWithResidualMarksRefused() throws {
        let verdict = copy(
            try validBan(mandate: fixtureMandate()),
            disposition: .dismiss,
            marks: Marks(caseOpen: true, banned: false),
            executeAfter: .some(nil)
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    // MARK: - Signature enforcement

    func testEnforcedSignatureAcceptsProperlySignedVerdict() throws {
        // Signed by the key the consented manifest names as its
        // `operator` — the validator derives the verifier from there.
        let mandate = fixtureMandate()
        let unsigned = try validBan(mandate: mandate)
        let signature = try Self.operatorKey.signature(for: try unsigned.signingBytes())
        let signed = Verdict(
            caseId: unsigned.caseId,
            authority: unsigned.authority,
            mandateRef: unsigned.mandateRef,
            accusedKeys: unsigned.accusedKeys,
            deviceBinding: unsigned.deviceBinding,
            classId: unsigned.classId,
            disposition: unsigned.disposition,
            marks: unsigned.marks,
            banExpires: unsigned.banExpires,
            executeAfter: unsigned.executeAfter,
            reasoning: unsigned.reasoning,
            appealDeadline: unsigned.appealDeadline,
            decidedAt: unsigned.decidedAt,
            signature: signature.base64EncodedString(),
            isFinal: unsigned.isFinal
        )
        let outcome = try validator.validate(
            signed,
            mandate: mandate,
            consented: try fixtureManifest(),
            now: now,
            enforceSignature: true
        )
        XCTAssertEqual(outcome, .execute)
    }

    /// A verdict signed by anyone other than the consented manifest's
    /// operator must not execute under enforcement.
    func testEnforcedSignatureRejectsWrongKey() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let mandate = fixtureMandate()
        let unsigned = try validBan(mandate: mandate)
        let signature = try signingKey.signature(for: try unsigned.signingBytes())
        let verdict = Verdict(
            caseId: unsigned.caseId,
            authority: unsigned.authority,
            mandateRef: unsigned.mandateRef,
            accusedKeys: unsigned.accusedKeys,
            deviceBinding: unsigned.deviceBinding,
            classId: unsigned.classId,
            disposition: unsigned.disposition,
            marks: unsigned.marks,
            banExpires: unsigned.banExpires,
            executeAfter: unsigned.executeAfter,
            reasoning: unsigned.reasoning,
            appealDeadline: unsigned.appealDeadline,
            decidedAt: unsigned.decidedAt,
            signature: signature.base64EncodedString(),
            isFinal: unsigned.isFinal
        )
        XCTAssertThrowsError(try validator.validate(
            verdict,
            mandate: mandate,
            consented: try fixtureManifest(),
            now: now,
            enforceSignature: true
        ))
    }

    func testSoftModeAcceptsUnverifiableSignature() throws {
        // Default posture until real authorities sign verdicts: log
        // and accept, exactly like `ContractsTrust` soft mode.
        XCTAssertEqual(try validate(try validBan(mandate: fixtureMandate())), .execute)
    }
}
