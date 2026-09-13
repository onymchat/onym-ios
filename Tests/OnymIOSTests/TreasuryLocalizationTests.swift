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
