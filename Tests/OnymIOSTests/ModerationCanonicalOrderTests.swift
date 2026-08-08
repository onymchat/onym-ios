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
    private func keyOrder(of data: Data) throws -> [String] {
        // Scan the raw JSON rather than parsing: parsing into a
        // dictionary discards the very thing under test.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        var keys: [String] = []
        var index = text.startIndex
        var depth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" { depth -= 1 }
            if character == "\"", depth == 1 {
                let start = text.index(after: index)
                if let end = text[start...].firstIndex(of: "\"") {
                    let candidate = String(text[start..<end])
                    let after = text.index(after: end)
                    if after < text.endIndex, text[after] == ":" {
                        keys.append(candidate)
                    }
                    index = after
                    continue
                }
            }
            index = text.index(after: index)
        }
        return keys
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
                    authenticityProof: "c2VuZGVyLXNpZ25hdHVyZQ=="
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

    /// The objects that already cross this boundary sort identically
    /// under both rules — which is why the interface has interoperated
    /// so far. Pinned so a renamed field can't quietly change that.
    func test_mandateAndVerdictKeysAreUnaffectedByTheOrderingDifference() throws {
        for keys in [
            ["mandateVersion", "user", "interface", "authority", "manifestHash",
             "classes", "deviceBinding", "acceptedAt"],
            ["verdictVersion", "caseId", "authority", "mandateRef", "accusedKeys",
             "deviceBinding", "classId", "disposition", "marks", "banExpires",
             "executeAfter", "reasoning", "appealDeadline", "decidedAt", "final"],
        ] {
            let byteOrder = keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            let object = Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) })
            let serialized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertEqual(try keyOrder(of: serialized), byteOrder)
        }
    }

    // MARK: - Response and appeal

    func test_responseAndAppealSigningBytesExcludeTheirSignature() throws {
        let response = CaseResponse(statement: "context changes its meaning", signature: "c2ln")
        XCTAssertEqual(try keyOrder(of: try response.signingBytes()), ["evidence", "statement"])

        let appeal = AppealSubmission(kind: .newHolderClaim, statement: "I bought this phone", signature: "c2ln")
        XCTAssertEqual(try keyOrder(of: try appeal.signingBytes()), ["kind", "statement"])
    }

    /// Signing bytes must not change when the signature is attached —
    /// otherwise attaching it would invalidate it.
    func test_signingBytesAreIndependentOfTheSignatureField() throws {
        var report = makeReport()
        let before = try report.signingBytes()
        report.signature = "ZGlmZmVyZW50LXNpZ25hdHVyZQ=="
        XCTAssertEqual(try report.signingBytes(), before)
    }
}
