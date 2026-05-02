import XCTest
@testable import OnymIOS

/// Sanity tests that every chain-layer enum case has a non-empty,
/// genuinely-localised `displayName`. "Genuinely localised" =
/// different from the enum's raw value, which would otherwise be the
/// fallback when `String(localized:)` can't find the key in the
/// catalog. These together catch the common regression: someone adds
/// a new enum case without adding its English string to
/// `Localizable.xcstrings`.
///
/// Doesn't directly inspect the `.xcstrings` JSON — that file gets
/// compiled to per-locale `.strings` at build time and isn't shipped
/// to the test bundle as a single document. The fallback-detection
/// trick above is a reliable proxy.
final class LocalizationCatalogTests: XCTestCase {

    // MARK: - RelayerStrategy

    func test_relayerStrategy_allCases_haveNonEmptyDisplayName() {
        for strategy in RelayerStrategy.allCases {
            XCTAssertFalse(strategy.displayName.isEmpty,
                           "RelayerStrategy.\(strategy.rawValue) has empty displayName")
        }
    }

    func test_relayerStrategy_displayName_isLocalizedNotRawFallback() {
        for strategy in RelayerStrategy.allCases {
            XCTAssertNotEqual(strategy.displayName, strategy.rawValue,
                              "RelayerStrategy.\(strategy.rawValue) displayName equals rawValue — likely missing from catalog")
        }
    }

    // MARK: - ContractNetwork

    func test_contractNetwork_allCases_haveNonEmptyDisplayName() {
        for network in ContractNetwork.allCases {
            XCTAssertFalse(network.displayName.isEmpty,
                           "ContractNetwork.\(network.rawValue) has empty displayName")
        }
    }

    func test_contractNetwork_displayName_isLocalizedNotRawFallback() {
        for network in ContractNetwork.allCases {
            XCTAssertNotEqual(network.displayName, network.rawValue,
                              "ContractNetwork.\(network.rawValue) displayName equals rawValue — likely missing from catalog")
        }
    }

    // MARK: - GovernanceType

    func test_governanceType_allCases_haveNonEmptyDisplayName() {
        for type in GovernanceType.allCases {
            XCTAssertFalse(type.displayName.isEmpty,
                           "GovernanceType.\(type.rawValue) has empty displayName")
        }
    }

    func test_governanceType_displayName_isLocalizedNotRawFallback() {
        for type in GovernanceType.allCases {
            XCTAssertNotEqual(type.displayName, type.rawValue,
                              "GovernanceType.\(type.rawValue) displayName equals rawValue — likely missing from catalog")
        }
    }

    // MARK: - source-of-truth catalog (read raw JSON via #filePath)

    /// Reads the source `.xcstrings` directly off disk (fragile under
    /// SPM / CI rebuilds where source files live elsewhere — but on
    /// the dev machine and the project's GH Actions runner this works
    /// fine and gives a one-shot sweep that catches missing
    /// translations across the entire catalog, not just chain enums).
    func test_localizable_xcstrings_everyKey_hasEnAndRu() throws {
        // .../Tests/OnymIOSTests/LocalizationCatalogTests.swift → up 2 → repo root → Resources/Localizable.xcstrings
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")

        guard let data = try? Data(contentsOf: catalog) else {
            throw XCTSkip("Localizable.xcstrings not reachable from \(thisFile.path) — likely running under SPM where #filePath doesn't resolve to the source tree")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = (json?["strings"] as? [String: Any]) ?? [:]
        XCTAssertFalse(strings.isEmpty, "catalog has no strings")

        var missing: [String] = []
        for (key, raw) in strings {
            let entry = raw as? [String: Any] ?? [:]
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            let hasEn = isPopulated(locs["en"])
            let hasRu = isPopulated(locs["ru"])
            if !hasEn || !hasRu {
                missing.append("\(key) [en=\(hasEn) ru=\(hasRu)]")
            }
        }
        XCTAssertTrue(missing.isEmpty, "missing translations:\n  - " + missing.sorted().joined(separator: "\n  - "))
    }

    /// A localisation has either a flat stringUnit value OR variations
    /// (plural / device / width). We treat any populated form as
    /// "translated" — partial coverage of a plural variant is still
    /// flagged because the dict won't even appear without at least
    /// one populated leaf.
    private func isPopulated(_ raw: Any?) -> Bool {
        guard let dict = raw as? [String: Any] else { return false }
        if let unit = dict["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String, !value.isEmpty {
            return true
        }
        if let variations = dict["variations"] as? [String: Any], !variations.isEmpty {
            return true
        }
        return false
    }
}
