import XCTest
import OnymModeration

/// Key ordering in the signed payloads.
///
/// Signing bytes only work if the *other* side can reproduce them, and
/// the other side is a moderation authority that may be written in any
/// language. Every mainstream JSON library sorts object keys by UTF-8
/// byte order — with one exception that ships in this very process:
/// `JSONSerialization`'s `.sortedKeys` sorts *case-insensitively*,
/// unlike `JSONEncoder`'s option of the same name.
///
/// Among the moderation objects only `Report` has keys that disagree
/// between those two rules, so it is the one that would break, and it
/// would break silently — as "every report signature is invalid".
/// These tests pin the byte-order rule so a future switch to
/// `JSONSerialization` fails here instead.
final class ModerationCanonicalOrderTests: XCTestCase {
    private func keyOrder(of data: Data, atDepth targetDepth: Int = 1) throws -> [String] {
        // Scan the raw JSON rather than parsing: parsing into a
        // dictionary discards the very thing under test.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        var keys: [String] = []
        var index = text.startIndex
        var depth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "{" || character == "[" {
                depth += 1
                index = text.index(after: index)
                continue
            }
            if character == "}" || character == "]" {
                depth -= 1
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                var cursor = text.index(after: index)
                var candidate = ""
                var escaped = false
                while cursor < text.endIndex {
                    let current = text[cursor]
                    if escaped {
                        candidate.append(current)
                        escaped = false
                    } else if current == "\\" {
                        escaped = true
                    } else if current == "\"" {
                        break
                    } else {
                        candidate.append(current)
                    }
                    cursor = text.index(after: cursor)
                }
                guard cursor < text.endIndex else {
                    XCTFail("unterminated JSON string")
                    return keys
                }

                var after = text.index(after: cursor)
                while after < text.endIndex, text[after].isWhitespace {
                    after = text.index(after: after)
                }
                if depth == targetDepth, after < text.endIndex, text[after] == ":" {
                    keys.append(candidate)
                }
                index = after
                continue
            }
            index = text.index(after: index)
        }
        return keys
    }

    private func byteOrdered(_ keys: [String]) -> [String] {
        keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    private func makeReport() -> Report {
        Report(
            reportId: "report-1",
            reporter: "onym:key:\(String(repeating: "ab", count: 32))",
            reporterMandate: String(repeating: "1", count: 64),
            accused: "onym:key:\(String(repeating: "cd", count: 32))",
            classId: "unsolicited-pornography",
            evidence: [
                EvidenceItem(
                    disclosedContent: "the disclosed message",
                    authenticityProof: "c2VuZGVyLXNpZ25hdHVyZQ==",
                    context: "the preceding exchange"
                )
            ],
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signature: "cmVwb3J0ZXItc2ln"
        )
    }

    /// The case that actually differs between the two Foundation
    /// rules. Byte order puts the capitalised `I`/`V` before lowercase
    /// `e`; a case-insensitive sort puts `reporter*` first.
    func test_reportSigningBytes_sortKeysByByteOrderNotCaseInsensitively() throws {
        let order = try keyOrder(of: try makeReport().signingBytes())

        let reportId = try XCTUnwrap(order.firstIndex(of: "reportId"))
        let reportVersion = try XCTUnwrap(order.firstIndex(of: "reportVersion"))
        let reporter = try XCTUnwrap(order.firstIndex(of: "reporter"))
        let reporterMandate = try XCTUnwrap(order.firstIndex(of: "reporterMandate"))

        XCTAssertLessThan(reportId, reporter, "byte order puts reportId before reporter")
        XCTAssertLessThan(reportVersion, reporter, "byte order puts reportVersion before reporter")
        XCTAssertLessThan(reporter, reporterMandate)
    }

    /// The whole key list, so any reordering — not just the collision
    /// above — is caught.
    func test_reportSigningBytes_haveTheExactByteOrderedKeyList() throws {
        XCTAssertEqual(
            try keyOrder(of: try makeReport().signingBytes()),
            [
                "accused",
                "classId",
                "evidence",
                "filedAt",
                "reportId",
                "reportVersion",
                "reporter",
                "reporterMandate",
            ]
        )
    }

    func test_reportSigningBytes_haveTheExactNestedEvidenceKeyOrder() throws {
        XCTAssertEqual(
            try keyOrder(of: try makeReport().signingBytes(), atDepth: 3),
            ["authenticityProof", "context", "disclosedContent"]
        )
    }

    /// Guard against anyone "simplifying" the encoder: this is what the
    /// bytes would look like if produced through `JSONSerialization`,
    /// and it must not be what we emit.
    func test_jsonSerializationOrderingWouldDifferFromOurs() throws {
        let ours = try keyOrder(of: try makeReport().signingBytes())

        let viaSerialization = try JSONSerialization.data(
            withJSONObject: ["reportId": 1, "reportVersion": 2, "reporter": 3],
            options: [.sortedKeys]
        )
        let theirs = try keyOrder(of: viaSerialization)

        // If Foundation ever makes the two agree this assertion fails,
        // which is the right moment to revisit the comment in
        // `ModerationCanonicalEncoder`.
        XCTAssertEqual(theirs, ["reporter", "reportId", "reportVersion"])
        let oursCollisionPart = ours.filter { theirs.contains($0) }
        XCTAssertNotEqual(oursCollisionPart, theirs)
    }

    /// Pin the ordering check to the actual signed forms rather than
    /// parallel hardcoded key lists that can drift from the types.
    func test_mandateAndVerdictSigningBytes_sortKeysByByteOrder() throws {
        let mandateKeys = try keyOrder(of: try makeMandate().signingBytes())
        XCTAssertEqual(mandateKeys, byteOrdered(mandateKeys))

        let verdictKeys = try keyOrder(of: try makeVerdict().signingBytes())
        XCTAssertEqual(verdictKeys, byteOrdered(verdictKeys))
    }

    // MARK: - Response and appeal

    func test_responseAndAppealSigningBytesExcludeTheirSignature() throws {
        let response = CaseResponse(
            caseId: "case-1",
            statement: #"context { changes "its" [meaning] }"#,
            signature: "c2ln"
        )
        XCTAssertEqual(try keyOrder(of: try response.signingBytes()), ["caseId", "evidence", "statement"])

        let appeal = AppealSubmission(
            caseId: "case-1",
            kind: .newHolderClaim,
            statement: "I bought this phone",
            signature: "c2ln"
        )
        XCTAssertEqual(try keyOrder(of: try appeal.signingBytes()), ["caseId", "kind", "statement"])
    }

    /// The case a response answers is *inside* what gets signed. Left
    /// outside, the same signed bytes would verify against any case,
    /// and an answer to one accusation could be replayed as an answer
    /// to another the signer never saw.
    func test_responseAndAppealSigningBytesBindTheirCase() throws {
        let first = CaseResponse(caseId: "case-1", statement: "not me")
        let second = CaseResponse(caseId: "case-2", statement: "not me")
        XCTAssertNotEqual(try first.signingBytes(), try second.signingBytes())

        let appealed = AppealSubmission(caseId: "case-1", kind: .appeal, statement: "wrong")
        let elsewhere = AppealSubmission(caseId: "case-2", kind: .appeal, statement: "wrong")
        XCTAssertNotEqual(try appealed.signingBytes(), try elsewhere.signingBytes())
    }

    /// Signing bytes must not change when the signature is attached —
    /// otherwise attaching it would invalidate it.
    func test_signingBytesAreIndependentOfTheSignatureField() throws {
        var report = makeReport()
        let before = try report.signingBytes()
        report.signature = "ZGlmZmVyZW50LXNpZ25hdHVyZQ=="
        XCTAssertEqual(try report.signingBytes(), before)
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
}
