import XCTest
import OnymModeration

/// Drift guard for the two PROVISIONAL signed payloads. Both
/// `signingBytes()` helpers are built from an explicit mirror type, so a
/// field added to the object without being added to the mirror would
/// silently fall outside the signature. These tests pin the key sets:
/// signed form == encoded form minus the signature field(s).
final class ModerationSigningPayloadTests: XCTestCase {
    private func keys(of data: Data) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return Set(dictionary.keys)
    }

    private func encodedKeys(of value: some Encodable) throws -> Set<String> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try keys(of: encoder.encode(value))
    }

    private func makeMandate() -> ModerationMandate {
        ModerationMandate(
            user: "onym:key:\(String(repeating: "ab", count: 32))",
            interface: ModerationRepository.interfaceComponentId,
            authority: "onym:component:test-authority",
            manifestHash: String(repeating: "0", count: 64),
            classes: ["unsolicited-pornography"],
            deviceBinding: "enrollment-1",
            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signatures: ["dXNlci1zaWc="]
        )
    }

    private func makeVerdict() -> Verdict {
        Verdict(
            caseId: "case-1",
            authority: "onym:component:test-authority",
            mandateRef: String(repeating: "1", count: 64),
            accusedKeys: ["onym:key:\(String(repeating: "ab", count: 32))"],
            deviceBinding: "enrollment-1",
            classId: "unsolicited-pornography",
            disposition: .ban,
            marks: Marks(caseOpen: false, banned: true),
            banExpires: Date(timeIntervalSince1970: 1_800_000_000),
            executeAfter: Date(timeIntervalSince1970: 1_700_000_000),
            reasoning: "reasoning-hash",
            appealDeadline: Date(timeIntervalSince1970: 1_700_000_000),
            decidedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signature: "YXV0aG9yaXR5LXNpZw==",
            isFinal: false
        )
    }

    // MARK: - Mandate

    func test_mandateSigningBytes_coverEveryFieldExceptSignatures() throws {
        let mandate = makeMandate()
        let signed = try keys(of: mandate.signingBytes())
        XCTAssertEqual(signed, try encodedKeys(of: mandate).subtracting(["signatures"]))
        XCTAssertFalse(signed.contains("signatures"))
    }

    /// The signed form carries no `signatures` field at all, so the
    /// interface countersignature can't change what the user signed —
    /// which is what makes `mandateHash()` a stable `mandateRef`.
    func test_mandateHash_isStableAcrossCountersigning() throws {
        var mandate = makeMandate()
        let before = try mandate.mandateHash()
        mandate.signatures.append(StubEnforcementBackendClient.countersignSentinel)
        XCTAssertEqual(before, try mandate.mandateHash())
    }

    // MARK: - Verdict

    func test_verdictSigningBytes_coverEveryFieldExceptSignature() throws {
        let verdict = makeVerdict()
        let signed = try keys(of: verdict.signingBytes())
        XCTAssertEqual(signed, try encodedKeys(of: verdict).subtracting(["signature"]))
        XCTAssertFalse(signed.contains("signature"))
    }
}
