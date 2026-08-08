import XCTest
@testable import OnymModeration

/// The consented-terms bounds (Moderation.md §5.6 constraint 3) and the
/// consent-time validity conditions. These are the checks that make the
/// seat's central promise real: the sanction a user can receive is the
/// one they read before signing.
final class ConsentedTermsEnforcementTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let validator = VerdictValidator()

    // MARK: - Fixtures

    /// `csam` permanent / non-suspensive; `unsolicited-pornography`
    /// P90D / suspensive with a P30D appeal window.
    private static let manifestBytes = Data("""
    {
      "version": 1,
      "componentId": "onym:component:authority",
      "seat": "moderation",
      "operator": "onym:key:1111111111111111111111111111111111111111111111111111111111111111",
      "moderationProfileId": "onym:moderation-profile:consent-bound-v1",
      "violationClasses": [
        {
          "classId": "csam",
          "definition": "hash:csam",
          "responseWindow": "P3D",
          "decisionDeadline": "P7D",
          "banTerm": "permanent",
          "appealWindow": "P30D",
          "appealEffect": "non-suspensive"
        },
        {
          "classId": "unsolicited-pornography",
          "definition": "hash:up",
          "responseWindow": "P7D",
          "decisionDeadline": "P14D",
          "banTerm": "P90D",
          "appealWindow": "P30D",
          "appealEffect": "suspensive"
        }
      ],
      "appellate": "onym:component:appellate",
      "newHolderAppeal": "hash:new-holder",
      "validUntil": "2030-01-01T00:00:00Z"
    }
    """.utf8)

    private func consented() throws -> SignedManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return SignedManifest(
            manifest: try decoder.decode(AuthorityManifest.self, from: Self.manifestBytes),
            rawBytes: Self.manifestBytes
        )
    }

    private func mandate() throws -> ModerationMandate {
        ModerationMandate(
            user: "onym:key:user",
            interface: "onym:component:onym-ios",
            authority: "onym:component:authority",
            manifestHash: try consented().manifestHash,
            classes: ["csam", "unsolicited-pornography"],
            deviceBinding: "enrollment-1",
            acceptedAt: now.addingTimeInterval(-100 * 86_400),
            signatures: ["user-sig"]
        )
    }

    /// A conforming executed suspensive ban: decided 40 days ago,
    /// appeal window (P30D) lapsed 10 days ago, execution began there,
    /// expiry is execution + the consented P90D.
    private func suspensiveBan(
        appealDeadline overrideAppeal: Date? = nil,
        executeAfter overrideExecute: Date? = nil,
        banExpires overrideExpiry: Date? = nil
    ) throws -> Verdict {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let appealDeadline = overrideAppeal ?? decidedAt.addingTimeInterval(30 * 86_400)
        let executeAfter = overrideExecute ?? appealDeadline
        return Verdict(
            caseId: "case-1",
            authority: "onym:component:authority",
            mandateRef: try mandate().mandateHash(),
            accusedKeys: ["onym:key:user"],
            deviceBinding: "enrollment-1",
            classId: "unsolicited-pornography",
            disposition: .ban,
            marks: Marks(caseOpen: false, banned: true),
            banExpires: overrideExpiry ?? executeAfter.addingTimeInterval(90 * 86_400),
            executeAfter: executeAfter,
            reasoning: "hash:findings",
            appealDeadline: appealDeadline,
            decidedAt: decidedAt,
            signature: "unsigned-fixture",
            isFinal: false
        )
    }

    private func validate(_ verdict: Verdict) throws -> VerdictValidator.Outcome {
        try validator.validate(
            verdict,
            mandate: try mandate(),
            consented: try consented(),
            now: now,
            enforceSignature: false
        )
    }

    // MARK: - Baseline

    func testConformingSuspensiveBanExecutes() throws {
        XCTAssertEqual(try validate(try suspensiveBan()), .execute)
    }

    // MARK: - Ban term

    /// The headline case from the review: a P90D class carrying a
    /// ten-year expiry must not validate.
    func testBanExpiryBeyondConsentedTermRefused() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let executeAfter = decidedAt.addingTimeInterval(30 * 86_400)
        let verdict = try suspensiveBan(
            banExpires: executeAfter.addingTimeInterval(3650 * 86_400)
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    func testBanExpiryShorterThanConsentedTermRefused() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let executeAfter = decidedAt.addingTimeInterval(30 * 86_400)
        let verdict = try suspensiveBan(
            banExpires: executeAfter.addingTimeInterval(10 * 86_400)
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    /// Expiry runs from execution, not decision (§5.6 constraint 3) —
    /// for a suspensive class those differ by the appeal window.
    func testBanExpiryMeasuredFromExecutionNotDecision() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let verdict = try suspensiveBan(
            banExpires: decidedAt.addingTimeInterval(90 * 86_400)
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    func testPermanentClassCarryingExpiryRefused() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let verdict = Verdict(
            caseId: "case-1",
            authority: "onym:component:authority",
            mandateRef: try mandate().mandateHash(),
            accusedKeys: ["onym:key:user"],
            deviceBinding: "enrollment-1",
            classId: "csam",
            disposition: .ban,
            marks: Marks(caseOpen: false, banned: true),
            banExpires: now.addingTimeInterval(365 * 86_400),
            executeAfter: decidedAt,
            reasoning: "hash:findings",
            appealDeadline: decidedAt.addingTimeInterval(30 * 86_400),
            decidedAt: decidedAt,
            signature: "unsigned-fixture",
            isFinal: false
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    // MARK: - Appeal window

    /// The other headline case: an authority must not be able to
    /// collapse the consented appeal window to nothing.
    func testZeroAppealWindowRefused() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let verdict = try suspensiveBan(
            appealDeadline: decidedAt,
            executeAfter: decidedAt
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    func testAppealDeadlineBeyondConsentedWindowRefused() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let stretched = decidedAt.addingTimeInterval(60 * 86_400)
        let verdict = try suspensiveBan(appealDeadline: stretched, executeAfter: stretched)
        XCTAssertThrowsError(try validate(verdict))
    }

    /// Non-suspensive bans previously escaped the appeal-deadline check
    /// entirely by omitting the field.
    func testNonSuspensiveBanMissingAppealDeadlineRefused() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let verdict = Verdict(
            caseId: "case-1",
            authority: "onym:component:authority",
            mandateRef: try mandate().mandateHash(),
            accusedKeys: ["onym:key:user"],
            deviceBinding: "enrollment-1",
            classId: "csam",
            disposition: .ban,
            marks: Marks(caseOpen: false, banned: true),
            banExpires: nil,
            executeAfter: decidedAt,
            reasoning: "hash:findings",
            appealDeadline: nil,
            decidedAt: decidedAt,
            signature: "unsigned-fixture",
            isFinal: false
        )
        XCTAssertThrowsError(try validate(verdict))
    }

    /// Whole-day windows computed elsewhere can land a second off;
    /// that must not reject an otherwise conforming verdict.
    func testSubSecondRoundingTolerated() throws {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let appealDeadline = decidedAt.addingTimeInterval(30 * 86_400 + 0.4)
        let verdict = try suspensiveBan(
            appealDeadline: appealDeadline,
            executeAfter: appealDeadline,
            banExpires: appealDeadline.addingTimeInterval(90 * 86_400 - 0.4)
        )
        XCTAssertEqual(try validate(verdict), .execute)
    }

    // MARK: - Consent-time manifest validity

    private func validateManifest(_ json: String) throws {
        let bytes = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let signed = SignedManifest(
            manifest: try decoder.decode(AuthorityManifest.self, from: bytes),
            rawBytes: bytes
        )
        try AuthorityManifestValidator().validateForConsent(signed, now: now)
    }

    private func manifestJSON(
        componentId: String = "onym:component:authority",
        appellate: String? = "onym:component:appellate",
        newHolderAppeal: String? = "hash:new-holder",
        banTerm: String = "permanent"
    ) -> String {
        let appellateLine = appellate.map { "\"appellate\": \"\($0)\"," } ?? ""
        let newHolderLine = newHolderAppeal.map { "\"newHolderAppeal\": \"\($0)\"," } ?? ""
        return """
        {
          "version": 1,
          "componentId": "\(componentId)",
          "seat": "moderation",
          "operator": "onym:key:1111111111111111111111111111111111111111111111111111111111111111",
          "moderationProfileId": "onym:moderation-profile:consent-bound-v1",
          "violationClasses": [
            {
              "classId": "csam",
              "definition": "hash:csam",
              "responseWindow": "P3D",
              "decisionDeadline": "P7D",
              "banTerm": "\(banTerm)",
              "appealWindow": "P30D",
              "appealEffect": "non-suspensive"
            }
          ],
          \(appellateLine)
          \(newHolderLine)
          "validUntil": "2030-01-01T00:00:00Z"
        }
        """
    }

    func testAcceptsConformingManifest() throws {
        XCTAssertNoThrow(try validateManifest(manifestJSON()))
    }

    /// §5.2 constraint 2 exists so no permanent sanction depends on its
    /// issuer staying alive — an issuer naming itself defeats it.
    func testIssuerAsOwnAppellateRefused() throws {
        XCTAssertThrowsError(
            try validateManifest(manifestJSON(appellate: "onym:component:authority"))
        )
    }

    func testNonComponentAppellateRefused() throws {
        for appellate in [
            "self",
            "",
            "the appeals board",
            "https://authority.example/appeals",
            // The bare prefix carries the right shape while naming
            // nobody — an appellate that resolves to no component can
            // hear no appeal.
            "onym:component:",
            "onym:component:   ",
            "onym:component:has whitespace",
        ] {
            XCTAssertThrowsError(
                try validateManifest(manifestJSON(appellate: appellate)),
                appellate
            )
        }
    }

    /// A manifest whose own `componentId` doesn't resolve can't
    /// establish that its appellate is anyone else.
    func testUnparseableIssuerComponentIdRefusedForPermanentClass() throws {
        XCTAssertThrowsError(
            try validateManifest(manifestJSON(componentId: "onym:component:"))
        )
        XCTAssertThrowsError(
            try validateManifest(manifestJSON(componentId: "authority"))
        )
    }

    // MARK: - ComponentReference

    func testComponentReferenceParsesAndRejects() throws {
        XCTAssertEqual(
            try ComponentReference.identifier(from: "onym:component:appellate"),
            "appellate"
        )
        XCTAssertEqual(
            ComponentReference.reference(for: "appellate"),
            "onym:component:appellate"
        )
        for bad in [
            "",
            "onym:component:",
            "onym:component: ",
            "onym:component:\t",
            "onym:component:a b",
            "appellate",
            "onym:key:00",
            "ONYM:COMPONENT:appellate",
        ] {
            XCTAssertThrowsError(try ComponentReference.identifier(from: bad), bad)
        }
    }

    func testNamesSameComponentIsFalseForUnparseableReferences() {
        XCTAssertTrue(
            ComponentReference.namesSameComponent("onym:component:a", "onym:component:a")
        )
        XCTAssertFalse(
            ComponentReference.namesSameComponent("onym:component:a", "onym:component:b")
        )
        // Two identically-malformed references must not read as "the
        // same component" — neither names one.
        XCTAssertFalse(
            ComponentReference.namesSameComponent("onym:component:", "onym:component:")
        )
    }

    func testMissingAppellateRefusedOnlyForPermanentClasses() throws {
        XCTAssertThrowsError(try validateManifest(manifestJSON(appellate: nil)))
        // A duration class needs no external appellate.
        XCTAssertNoThrow(try validateManifest(manifestJSON(appellate: nil, banTerm: "P90D")))
    }

    /// Device marks survive resale, so the new-holder remedy is
    /// mandatory (§5.7) — a manifest without one can't deliver it.
    func testMissingNewHolderAppealRefused() throws {
        XCTAssertThrowsError(try validateManifest(manifestJSON(newHolderAppeal: nil)))
        XCTAssertThrowsError(try validateManifest(manifestJSON(newHolderAppeal: "")))
    }

    func testExpiredManifestRefused() throws {
        let expired = manifestJSON().replacingOccurrences(
            of: "\"validUntil\": \"2030-01-01T00:00:00Z\"",
            with: "\"validUntil\": \"2020-01-01T00:00:00Z\""
        )
        XCTAssertThrowsError(try validateManifest(expired))
    }

    func testUnsupportedProfileRefused() throws {
        let other = manifestJSON().replacingOccurrences(
            of: "onym:moderation-profile:consent-bound-v1",
            with: "onym:profile:something-else"
        )
        XCTAssertThrowsError(try validateManifest(other)) { error in
            XCTAssertEqual(
                error as? ModerationError,
                .unsupportedProfile("onym:profile:something-else")
            )
        }
    }

    /// The spec fixes this string (§5.1 profile, §5.2 manifest); a
    /// conforming manifest must be accepted by default.
    func testSpecProfileIdIsSupportedByDefault() {
        XCTAssertTrue(
            AuthorityManifestValidator.defaultSupportedProfileIds
                .contains("onym:moderation-profile:consent-bound-v1")
        )
    }
}
