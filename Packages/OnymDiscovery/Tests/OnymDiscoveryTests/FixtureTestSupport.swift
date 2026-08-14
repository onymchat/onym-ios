import Foundation
import XCTest
@testable import OnymDiscovery

/// Byte-exact conformance fixtures copied from
/// `onym-discovery/tests/fixtures` — the cross-language vectors every
/// consuming client must pass identically (profile §10).
enum Fixture {
    /// A fixture that should be in the bundle but is not. A **failure**,
    /// never an `XCTSkip`: skipping would let the §10 conformance suite
    /// pass vacuously with the vectors missing.
    struct MissingFixtureError: Error, CustomStringConvertible {
        let name: String
        var description: String {
            "missing conformance fixture \(name) — the suite must not pass without its vectors"
        }
    }

    static func bytes(_ name: String) throws -> Data {
        let parts = name.split(separator: ".")
        guard let url = Bundle.module.url(
            forResource: String(parts.dropLast().joined(separator: ".")),
            withExtension: String(parts.last ?? ""),
            subdirectory: "Fixtures"
        ) else {
            throw MissingFixtureError(name: name)
        }
        return try Data(contentsOf: url)
    }

    /// The fixtures' signing date neighborhood: validity spans
    /// 2026-08-13 → 2026-09-12 / 2026-12-31, so tests inject
    /// 2026-08-14T00:00:00Z as `now`.
    static let now = Date(timeIntervalSince1970: 1_786_665_600)

    /// The operator key inside `provider-manifest.json`'s `operator`.
    static let operatorKeyHex = "ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c"
}

extension XCTestCase {
    /// Assert the block throws a `DiscoveryTrustError` matching `check`.
    func assertThrowsTrustError<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (DiscoveryTrustError) -> Bool
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let trustError = error as? DiscoveryTrustError else {
                XCTFail("expected DiscoveryTrustError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(check(trustError), "unexpected error \(trustError)", file: file, line: line)
        }
    }
}
