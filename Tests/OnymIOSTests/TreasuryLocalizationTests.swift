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
    private static let patterns = [
        #"Text\("((?:[^"\\]|\\.)+)"\)"#,
        #"SectionLabel\("((?:[^"\\]|\\.)+)"\)"#,
        #"Footnote\("((?:[^"\\]|\\.)+)"\)"#,
        #"LargeTitle\("((?:[^"\\]|\\.)+)"\)"#,
        #"PrimaryButton\(\s*"((?:[^"\\]|\\.)+)""#,
        #"title: "((?:[^"\\]|\\.)+)""#,
        #"navigationTitle\("((?:[^"\\]|\\.)+)"\)"#,
        #"Button\("((?:[^"\\]|\\.)+)"\)"#,
        #"bullet\("((?:[^"\\]|\\.)+)"\)"#,
        #"line\(\s*"((?:[^"\\]|\\.)+)""#,
        // The parameters that exist so UI copy stops being rendered by
        // the non-localizing `Text(_: String)` overload. They are keys,
        // so they belong in the catalog, and the scanner has to know
        // that or adding them just moves the blind spot.
        #"subtitleKey: "((?:[^"\\]|\\.)+)""#,
        #"key: "((?:[^"\\]|\\.)+)""#,
        #"text = "((?:[^"\\]|\\.)+)""#,
    ]

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
                    guard let captured = Range(match.range(at: 1), in: source) else {
                        continue
                    }
                    let key = Self.catalogKey(String(source[captured]))
                    checked += 1
                    if !keys.contains(key) {
                        missing.append("\(url.lastPathComponent): \(key)")
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
        let patterns = [
            #"verbatim:\s*"((?:[^"\\]|\\.)*)""#,
            #"titleText:\s*"((?:[^"\\]|\\.)*)""#,
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
