import XCTest

/// Pins the rendered forms of the onboarding Done summary's count
/// trailings ("%lld services" / "%lld sources"). Same contract as
/// `DiscoveryEntriesLabelTests`: pluralization must come from the
/// catalog's per-locale plural variations, not an English-only `== 1`
/// branch — these hosted tests resolve the keys against the real app
/// bundle (`TEST_HOST` = OnymIOS.app).
final class OnboardingCountLabelsTests: XCTestCase {

    private func services(_ count: Int) -> String {
        String(localized: "\(count) services")
    }

    private func sources(_ count: Int) -> String {
        String(localized: "\(count) sources")
    }

    /// Whatever the run locale, the raw key must never leak and the
    /// count must be present.
    func test_labels_neverLeakRawKeys() {
        for count in [0, 1, 2, 5, 21] {
            for label in [services(count), sources(count)] {
                XCTAssertFalse(label.contains("%lld"),
                               "raw format key leaked: \(label)")
                XCTAssertTrue(label.contains("\(count)"),
                              "count missing from label: \(label)")
            }
        }
    }

    /// Exact English forms — the `one` variant must be reachable
    /// through the single interpolated key (the old split
    /// "1 service" / "N services" literals made it dead). Meaningful
    /// only when the test host resolves to English.
    func test_labels_englishPluralForms() throws {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true else {
            throw XCTSkip("test host is not resolving English localizations")
        }
        XCTAssertEqual(services(1), "1 service")
        XCTAssertEqual(services(0), "0 services")
        XCTAssertEqual(services(2), "2 services")
        XCTAssertEqual(sources(1), "1 source")
        XCTAssertEqual(sources(2), "2 sources")
    }
}
