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

    /// Where `TreasuryProposalDescription` keeps the card's own
    /// vocabulary — its labels, its titles, and its caveats.
    private static var descriptionPatterns: [String] {
        let body = "(" + literalBody + ")"
        return [
            #"label: ""# + body + #"""#,
            #"\.copy\(\s*""# + body + #""\)"#,
            #"title = ""# + body + #"""#,
            #"caveat = ""# + body + #"""#,
        ]
    }

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
            // The one call site that produces a `String` rather than a
            // key. A flow's `actionError` / `composeError` / `pasteError`
            // is handed to `reasonAlert` and to the compose sheets,
            // both of which render it with `Text(_: String)` — the
            // non-localizing overload — so the flow has to do the
            // lookup itself. These are keys like any other and belong
            // in the catalog.
            #"String\(\s*localized:\s*""# + body + #"""#,
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

        // Through the shared walker, not a second copy of it. Two
        // tests each building their own list is how one of them ended
        // up scanning a directory the other did not.
        let sources = try treasuryUISources()

        var missing: [String] = []
        var checked = 0
        for url in sources {
            let source = try String(contentsOf: url, encoding: .utf8)
            // The view layer's set includes a broad "a literal that
            // opens its own line" rule, which is right for a SwiftUI
            // body and wrong in a domain type full of literals that are
            // not keys. The description file is read with the narrow
            // set that names the three places its copy lives.
            let isDomain = url.pathComponents.contains("OnymTreasury")
            for pattern in isDomain ? Self.descriptionPatterns : Self.patterns {
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
            // The value chosen by a branch. `Footnote(verbatim: network
            // == .testnet ? "…" : "…")` put two English sentences on the
            // balance card and matched neither pattern above, because
            // what follows the colon is a condition rather than a quote
            // — so the check walked past two keys the catalog already
            // held a Russian translation for. `CreateTreasuryView`
            // states the rule the right way round: two catalog keys
            // chosen by a branch, not one string built by a branch.
            #"verbatim:[^"\n]*\?\s*""# + body + #"""#,
            #"titleText:[^"\n]*\?\s*""# + body + #"""#,
            #"text:[^"\n]*\?\s*""# + body + #"""#,
        ]
        var offenders: [String] = []
        for url in sources {
            // Continuation lines folded back in, so a ternary written
            // across three lines — which is how every one of them is
            // written once the arms are sentences — reads as the single
            // expression it is.
            let source = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(
                    of: #"\n\s*([?:])"#,
                    with: " $1",
                    options: .regularExpression
                )
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

    /// A message on its way to a screen is a `String`, and a `String`
    /// is rendered by `Text(_: String)` — the non-localizing overload,
    /// which is what `reasonAlert` and both compose sheets use. So a
    /// bare literal assigned to one is English in every language.
    ///
    /// This is the shape neither scanner above can see, and the reason
    /// is worth stating: they ask whether a *key* is in the catalog,
    /// and these were never keys. Twenty-five of them — every refusal
    /// the two treasury flows can give a co-signer, from "you haven't
    /// chosen a Stellar account" to "another transaction went first" —
    /// were plain literals while the catalog check passed.
    ///
    /// `String(localized:)` makes them keys, and the pattern above
    /// then holds them to the same catalog rule as everything else.
    func test_noTreasuryFlowMessage_bypassesTheCatalog() throws {
        let sources = try treasuryUISources()
        let regex = try NSRegularExpression(
            pattern: #"[A-Za-z]*(?:[Ee]rror|[Mm]essage)\s*=\s*""#
        )
        var offenders: [String] = []
        for url in sources {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let matched = Range(match.range, in: source) else { continue }
                let line = source[..<matched.lowerBound]
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .count
                offenders.append("\(url.lastPathComponent):\(line): \(source[matched])")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "flow messages assigned a literal instead of String(localized:):\n" +
                offenders.sorted().joined(separator: "\n")
        )
    }

    private func treasuryUISources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // Two roots, because this PR moved the feature's most
        // safety-critical copy — the proposal card's row labels, its
        // titles, and the red "Don't sign it" caveat — into
        // `TreasuryProposalDescription`, which ships in the domain
        // package. A scanner rooted only at `OnymTreasuryUI` would have
        // reported green over precisely that.
        //
        // The domain package contributes one file. The rest of it holds
        // strings that are *not* keys — the interactors' `.failed`
        // reasons, store key fragments — and those are a separate
        // problem: they reach the screen in English too, but fixing
        // them means changing what an outcome carries, which is wider
        // than a test should quietly require.
        let directories = [
            ["Packages", "OnymTreasuryUI", "Sources"],
            ["Packages", "OnymTreasury", "Sources"],
        ]
        let domainFiles = ["TreasuryProposalDescription.swift"]
        var found: [URL] = []
        for components in directories {
            let sources = components.reduce(root) { $0.appendingPathComponent($1) }
            guard let walker = FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil
            ) else {
                throw XCTSkip("treasury sources not reachable")
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if components.contains("OnymTreasury"),
                   !domainFiles.contains(url.lastPathComponent) {
                    continue
                }
                found.append(url)
            }
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
        // One level of nesting, so `\(Int(weight))` is matched whole —
        // `[^)]*` stopped at the inner paren and left a stray ")".
        while let match = result.range(
            of: #"\\\((?:[^()]|\([^()]*\))*\)"#,
            options: .regularExpression
        ) {
            let expression = result[match]
            let isInteger = ["count", "wrappedValue", "maximum", "Int("]
                .contains { expression.contains($0) }
            result.replaceSubrange(match, with: isInteger ? "%lld" : "%@")
        }
        return result
    }
}
