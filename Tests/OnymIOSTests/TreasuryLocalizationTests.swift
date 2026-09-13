import XCTest
@testable import OnymIOS

/// Every localizable literal in the treasury UI has a catalog entry.
///
/// `LocalizationCatalogTests` checks that keys **already in** the
/// catalog carry both languages. It cannot see a literal that was never
/// added — which is how ~55 treasury strings shipped rendering English
/// under `ru` while every test passed.
///
/// Scoped to the treasury sources rather than the whole app: the older
/// screens predate this check and sweeping them is a separate job.
final class TreasuryLocalizationTests: XCTestCase {

    /// Call sites whose first string literal is a `LocalizedStringKey`.
    /// `titleText:` / `verbatim:` initialisers are deliberately absent —
    /// those exist precisely so runtime data is never looked up as a key.
    /// One Swift string literal.
    ///
    /// Written once because the shapes that slip past a scanner like
    /// this are all the same mistake in different places: `[^"\\]`
    /// cannot cross a quote, and an interpolation may legitimately
    /// contain one — `"Waiting on \(names.joined(separator: ", "))"` is
    /// a single literal whose middle looks like the end of one. So an
    /// interpolation is consumed as a unit here, quotes and all.
    private static let literalBody =
        #"(?:[^"\\]|\\\((?:[^()"]|"[^"]*"|\([^()]*\))*\)|\\.)+"#

    /// Call sites whose first string literal is a `LocalizedStringKey`.
    /// `titleText:` / `verbatim:` / `Chip(text:)` are deliberately
    /// absent — those exist precisely so runtime data is never looked up
    /// as a key. They have a test of their own below.
    ///
    /// Every pattern allows whitespace before the quote, and there is a
    /// separate one for a ternary. Requiring the quote immediately after
    /// the label is what let eight strings through: `title:` followed by
    /// `flow.mine == nil ? "…" : "…"` matched nothing at all, and even a
    /// matching first branch left the second literal uncaptured. A
    /// scanner that reports green over the exact class of bug it was
    /// written for is worse than no scanner, so `test_theScanner…`
    /// below pins each shape against a fixture.
    private static var patterns: [String] {
        let body = "(" + literalBody + ")"
        return [
            #"Text\(\s*""# + body + #""\)"#,
            #"SectionLabel\(\s*""# + body + #""\)"#,
            #"Footnote\(\s*""# + body + #""\)"#,
            #"LargeTitle\(\s*""# + body + #""\)"#,
            #"PrimaryButton\(\s*""# + body + #"""#,
            #"title: \s*""# + body + #"""#,
            #"navigationTitle\(\s*""# + body + #""\)"#,
            #"Button\(\s*""# + body + #""\)"#,
            #"bullet\(\s*""# + body + #""\)"#,
            #"line\(\s*""# + body + #"""#,
            // The parameters that exist so UI copy stops being rendered
            // by the non-localizing `Text(_: String)` overload. They are
            // keys, so they belong in the catalog, and the scanner has
            // to know that or adding them just moves the blind spot.
            #"subtitleKey:\s*""# + body + #"""#,
            #"key:\s*""# + body + #"""#,
            #"text = ""# + body + #"""#,
            // Both arms of a ternary, in one pattern with two captures,
            // so neither can be the one that gets away.
            #"\?\s*""# + body + #""\s*:\s*""# + body + #"""#,
            // A literal that opens its own line: the else-arm of a
            // multi-line ternary, and the body of a `switch` case that
            // returns one implicitly.
            #"\n\s*[?:]?\s*""# + body + #"""#,
        ]
    }

    /// Shapes the scanner must find, and shapes it must leave alone.
    ///
    /// The reason this exists: the patterns above are the only thing
    /// standing between a new string and an English-only screen, and a
    /// regex that silently stops matching looks exactly like a screen
    /// with nothing wrong. Pinning them against a fixture turns "the
    /// scanner went blind" into a failing test rather than a Russian
    /// screenshot months later.
    func test_theScannerFindsTheShapesItClaimsTo() throws {
        let fixture = """
        Text("bare")
        Row(
            title: flow.empty ? "ternary then" : "ternary else",
            subtitleKey: "wrapped value"
        )
        Chip(
            key: someCondition
                ? "multiline then"
                : "multiline else",
        )
        Text("interpolated \\(names.joined(separator: ", ")) inside")
        Text(verbatim: "not a key")
        Row(titleText: "also not a key")
        """
        var found: Set<String> = []
        for pattern in Self.patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(fixture.startIndex..., in: fixture)
            for match in regex.matches(in: fixture, range: range) {
                for group in 1..<match.numberOfRanges {
                    guard let captured = Range(match.range(at: group), in: fixture) else {
                        continue
                    }
                    found.insert(String(fixture[captured]))
                }
            }
        }
        for expected in [
            "bare",
            "ternary then",
            "ternary else",
            "wrapped value",
            "multiline then",
            "multiline else",
            #"interpolated \(names.joined(separator: ", ")) inside"#,
        ] {
            XCTAssertTrue(found.contains(expected), "the scanner missed: \(expected)")
        }
        for excluded in ["not a key", "also not a key"] {
            XCTAssertFalse(found.contains(excluded), "the scanner claimed: \(excluded)")
        }
    }

    func test_everyTreasuryUIString_isInTheCatalog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let catalogURL = root
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")
        guard let data = try? Data(contentsOf: catalogURL) else {
            throw XCTSkip("catalog not reachable from \(#filePath)")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set((json?["strings"] as? [String: Any] ?? [:]).keys)
        XCTAssertFalse(keys.isEmpty)

        let sources = root
            .appendingPathComponent("Packages")
            .appendingPathComponent("OnymTreasuryUI")
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("treasury UI sources not reachable")
        }

        var missing: [String] = []
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in Self.patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(source.startIndex..., in: source)
                for match in regex.matches(in: source, range: range) {
                    // Every group, not just the first: the ternary
                    // pattern captures both arms, and reading one of
                    // them is how the else-arm stayed invisible.
                    for group in 1..<match.numberOfRanges {
                        guard let captured = Range(match.range(at: group), in: source) else {
                            continue
                        }
                        let literal = String(source[captured])
                        // SF Symbol names reach `Image(systemName:)`
                        // through the same ternaries copy does, and they
                        // are not words. Lowercase, unspaced and drawn
                        // from the symbol alphabet is what one looks
                        // like; `checkmark.circle.fill` and its bare
                        // `circle` sibling both qualify, and no copy on
                        // these screens does — UI sentences here begin
                        // with a capital.
                        let symbolAlphabet = CharacterSet(
                            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789."
                        )
                        if !literal.isEmpty,
                           literal.unicodeScalars.allSatisfy(symbolAlphabet.contains) {
                            continue
                        }
                        let key = Self.catalogKey(literal)
                        checked += 1
                        if !keys.contains(key) {
                            missing.append("\(url.lastPathComponent): \(key)")
                        }
                    }
                }
            }
        }

        XCTAssertGreaterThan(checked, 40, "the scanner found almost nothing — patterns stale?")
        XCTAssertTrue(
            missing.isEmpty,
            "treasury strings missing from Localizable.xcstrings:\n" +
                missing.sorted().joined(separator: "\n")
        )
    }

    /// `verbatim:` and `titleText:` exist so runtime data is never
    /// looked up as a key. A literal sentence passed to one of them is
    /// therefore always a mistake — it is not runtime data, and the
    /// non-localizing overload guarantees it renders English in every
    /// language.
    ///
    /// This is the blind spot the scanner above shipped with. The
    /// founder's funding footnote was two English sentences behind a
    /// `Footnote(verbatim:)`, and because the patterns only match
    /// `Footnote("`, the check walked straight past the exact class of
    /// bug it was written to catch.
    ///
    /// A literal with an interpolation in it is fine: that is what the
    /// overload is for. So is one with no letters in it — a bullet, a
    /// separator, a slash between two numbers.
    func test_noTreasuryUIString_hidesBehindVerbatim() throws {
        let sources = try treasuryUISources()
        let body = "(" + Self.literalBody + ")"
        let patterns = [
            #"verbatim:\s*""# + body + #"""#,
            #"titleText:\s*""# + body + #"""#,
            // `Chip(text:)` is the same trap under another name, and it
            // held two sentences on the declare screen — "Valid address"
            // and a character count — rendering English under every
            // language while the catalog looked complete. Matched on the
            // label alone: `text:` is not used for anything else in
            // these files.
            #"text:\s*""# + body + #"""#,
        ]
        var offenders: [String] = []
        for url in sources {
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(source.startIndex..., in: source)
                for match in regex.matches(in: source, range: range) {
                    guard let captured = Range(match.range(at: 1), in: source) else {
                        continue
                    }
                    let literal = String(source[captured])
                    guard !literal.contains("\\(") else { continue }
                    // Escapes resolved before the letter test: a bullet
                    // written `\u{2022}` has letters in its *source* and
                    // none in the character it denotes.
                    let rendered = Self.catalogKey(literal)
                    guard rendered.contains(where: { $0.isLetter }) else { continue }
                    offenders.append("\(url.lastPathComponent): \(literal)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "literal sentences behind a non-localizing initialiser:\n" +
                offenders.sorted().joined(separator: "\n")
        )
    }

    private func treasuryUISources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = root
            .appendingPathComponent("Packages")
            .appendingPathComponent("OnymTreasuryUI")
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("treasury UI sources not reachable")
        }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            found.append(url)
        }
        return found
    }

    /// The key SwiftUI actually looks up: escapes resolved, and
    /// interpolations replaced by the printf placeholder the catalog
    /// records.
    private static func catalogKey(_ literal: String) -> String {
        var result = literal
        // \u{2014} and friends.
        while let match = result.range(of: #"\\u\{[0-9A-Fa-f]+\}"#, options: .regularExpression) {
            let hex = result[match].dropFirst(3).dropLast()
            let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init)
            result.replaceSubrange(match, with: scalar.map { String(Character($0)) } ?? "")
        }
        // Interpolations. Integers format as %lld, everything else %@.
        while let match = result.range(of: #"\\\([^)]*\)"#, options: .regularExpression) {
            let expression = result[match]
            let isInteger = ["count", "wrappedValue", "maximum"]
                .contains { expression.contains($0) }
            result.replaceSubrange(match, with: isInteger ? "%lld" : "%@")
        }
        return result
    }
}
