import XCTest
import OnymSettings

/// Pins the rendered forms of the discovery source row's entry-count
/// line. Regression coverage for the raw-markup bug: the line used
/// `^[…](inflect: true)` automatic grammar agreement with no entry in
/// `Localizable.xcstrings`, so under an `-AppleLanguages` override the
/// label surfaced as the literal `^[1 catalog entries](inflect: true)`.
/// It now goes through the catalog's plural variations for the
/// `%lld catalog entries` key, which these hosted tests resolve against
/// the real app bundle (`TEST_HOST` = OnymIOS.app).
final class DiscoveryEntriesLabelTests: XCTestCase {

    /// Whatever the run locale, inflection markup must never leak into
    /// the label, and the count must be present.
    func test_label_neverLeaksInflectionMarkup() {
        for count in [0, 1, 2, 5, 21] {
            let label = DiscoveryEntriesLabel.text(count: count)
            XCTAssertFalse(label.contains("^["),
                           "raw inflection markup leaked: \(label)")
            XCTAssertFalse(label.contains("inflect"),
                           "raw inflection markup leaked: \(label)")
            XCTAssertTrue(label.contains("\(count)"),
                          "count missing from label: \(label)")
        }
    }

    /// Exact English forms — the plural rule must be the catalog's
    /// one/other variation, not a raw `%lld catalog entries` fallback
    /// for count == 1. Meaningful only when the test host resolves to
    /// English.
    func test_label_englishPluralForms() throws {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true else {
            throw XCTSkip("test host is not resolving English localizations")
        }
        XCTAssertEqual(DiscoveryEntriesLabel.text(count: 1), "1 catalog entry")
        XCTAssertEqual(DiscoveryEntriesLabel.text(count: 0), "0 catalog entries")
        XCTAssertEqual(DiscoveryEntriesLabel.text(count: 2), "2 catalog entries")
    }
}
