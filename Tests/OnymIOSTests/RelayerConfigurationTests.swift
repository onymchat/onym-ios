import XCTest
@testable import OnymIOS

/// Pure tests for `RelayerConfiguration.selectURL` — the resolver
/// chain interactors will call per request. No actor, no I/O, just
/// the strategy + primary fallback rules.
final class RelayerConfigurationTests: XCTestCase {
    private let a = RelayerEndpoint(name: "A", url: URL(string: "https://a.example")!, networks: ["testnet"])
    private let b = RelayerEndpoint(name: "B", url: URL(string: "https://b.example")!, networks: ["testnet"])
    private let c = RelayerEndpoint(name: "C", url: URL(string: "https://c.example")!, networks: ["public"])

    // MARK: - empty

    func test_selectURL_emptyEndpoints_returnsNil() {
        var rng = SeededRNG(seed: 1)
        let config = RelayerConfiguration.empty
        XCTAssertNil(config.selectURL(using: &rng))
    }

    func test_selectURL_emptyEndpoints_randomStrategy_alsoReturnsNil() {
        var rng = SeededRNG(seed: 1)
        let config = RelayerConfiguration(endpoints: [], primaryURL: nil, strategy: .random)
        XCTAssertNil(config.selectURL(using: &rng))
    }

    // MARK: - primary strategy

    func test_primary_returnsExplicitPrimary() {
        var rng = SeededRNG(seed: 1)
        let config = RelayerConfiguration(
            endpoints: [a, b, c],
            primaryURL: b.url,
            strategy: .primary
        )
        XCTAssertEqual(config.selectURL(using: &rng), b.url)
    }

    func test_primary_noExplicitPrimary_fallsBackToFirstEndpoint() {
        var rng = SeededRNG(seed: 1)
        let config = RelayerConfiguration(
            endpoints: [a, b],
            primaryURL: nil,
            strategy: .primary
        )
        XCTAssertEqual(config.selectURL(using: &rng), a.url,
                       "primary unset → first endpoint is the implicit primary")
    }

    func test_primary_primaryURLNotInList_fallsBackToFirstEndpoint() {
        // User removed the previously-primary endpoint but the
        // primaryURL slot wasn't cleared by the caller; resolver
        // tolerates this by falling back instead of returning nil.
        var rng = SeededRNG(seed: 1)
        let stale = URL(string: "https://stale.example")!
        let config = RelayerConfiguration(
            endpoints: [a, b],
            primaryURL: stale,
            strategy: .primary
        )
        XCTAssertEqual(config.selectURL(using: &rng), a.url)
    }

    func test_primary_singleEndpoint_returnsIt() {
        var rng = SeededRNG(seed: 1)
        let config = RelayerConfiguration(
            endpoints: [a],
            primaryURL: nil,
            strategy: .primary
        )
        XCTAssertEqual(config.selectURL(using: &rng), a.url)
    }

    // MARK: - random strategy

    func test_random_singleEndpoint_alwaysReturnsIt() {
        var rng = SeededRNG(seed: 1)
        let config = RelayerConfiguration(
            endpoints: [a],
            primaryURL: nil,
            strategy: .random
        )
        for _ in 0..<10 {
            XCTAssertEqual(config.selectURL(using: &rng), a.url)
        }
    }

    func test_random_multipleEndpoints_picksFromList() {
        // With a deterministic RNG, every selection must be one of
        // the configured endpoints. Run a bunch and verify membership.
        var rng = SeededRNG(seed: 42)
        let endpoints = [a, b, c]
        let allowed = Set(endpoints.map { $0.url })
        let config = RelayerConfiguration(
            endpoints: endpoints,
            primaryURL: nil,
            strategy: .random
        )
        for _ in 0..<50 {
            let url = try? XCTUnwrap(config.selectURL(using: &rng))
            XCTAssertTrue(allowed.contains(url ?? URL(string: "x:")!), "random pick must be one of the configured URLs")
        }
    }

    func test_random_ignoresPrimaryURL() {
        // primaryURL is meaningful only under .primary strategy.
        // Under .random it must not bias selection.
        var rng = SeededRNG(seed: 7)
        let config = RelayerConfiguration(
            endpoints: [a, b],
            primaryURL: a.url,  // would be returned under .primary
            strategy: .random
        )
        // Run 100 picks; expect both URLs to appear at least once.
        var seen: Set<URL> = []
        for _ in 0..<100 {
            if let url = config.selectURL(using: &rng) { seen.insert(url) }
        }
        XCTAssertEqual(seen, [a.url, b.url], "random must visit both endpoints; primaryURL is irrelevant")
    }

    // MARK: - codable

    func test_codable_roundtripsAllFields() throws {
        let config = RelayerConfiguration(
            endpoints: [a, b, c],
            primaryURL: b.url,
            strategy: .random,
            hasUserInteracted: true
        )
        let json = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RelayerConfiguration.self, from: json)
        XCTAssertEqual(decoded, config)
    }

    // MARK: - defaults

    func test_empty_strategy_isRandom() {
        XCTAssertEqual(RelayerConfiguration.empty.strategy, .random,
                       "default strategy is .random so a freshly-installed user gets load-balanced across the auto-populated relayer list out of the box")
    }

    func test_empty_hasUserInteracted_isFalse() {
        XCTAssertFalse(RelayerConfiguration.empty.hasUserInteracted,
                       ".empty represents a never-touched configuration so the auto-populate path can detect it")
    }

    // MARK: - backward compat

    func test_codable_decodesPR20WireShape_treatsMissingFlagAsInteracted() throws {
        // PR #20's wire format had no `hasUserInteracted` field. Existing
        // users with a saved configuration must NOT be treated as
        // never-interacted on app launch — that would let the auto-populate
        // path overwrite their custom URLs / explicit selections.
        let pr20JSON = """
        {
            "endpoints": [
                { "name": "Existing", "url": "https://existing.example", "network": "testnet" }
            ],
            "primaryURL": "https://existing.example",
            "strategy": "primary"
        }
        """
        let decoded = try JSONDecoder().decode(RelayerConfiguration.self, from: Data(pr20JSON.utf8))
        XCTAssertTrue(decoded.hasUserInteracted,
                      "absent flag must default to true so existing users aren't reset")
        XCTAssertEqual(decoded.endpoints.count, 1)
        XCTAssertEqual(decoded.strategy, .primary)
    }
}
