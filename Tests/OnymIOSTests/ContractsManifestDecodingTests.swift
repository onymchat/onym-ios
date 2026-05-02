import XCTest
@testable import OnymIOS

/// Pin the wire format + the unknown-enum-dropping behaviour of the
/// manifest decoder. A future contracts release that adds (e.g.) a
/// "monarchy" governance type or a "futurenet" network must not crash
/// older clients — the decoder silently drops those entries while
/// keeping the rest of the manifest usable.
final class ContractsManifestDecodingTests: XCTestCase {

    // MARK: - happy path

    func test_decodeFiltering_parsesValidManifest() throws {
        let manifest = try GitHubReleasesContractsManifestFetcher.decodeFiltering(Data(Self.fixtureJSON.utf8))
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.releases.count, 2)

        let v002 = try XCTUnwrap(manifest.releases.first { $0.release == "v0.0.2" })
        XCTAssertEqual(v002.contracts.count, 5)
        XCTAssertEqual(v002.contracts.first?.network, .testnet)
        XCTAssertEqual(v002.contracts.first?.type, .anarchy)
        XCTAssertEqual(v002.contracts.first?.id, "CDWYYK...RO2UMV")
    }

    // MARK: - unknown-enum dropping

    func test_decodeFiltering_dropsUnknownNetwork() throws {
        let json = """
        {
          "version": 1,
          "releases": [{
            "release": "v0.0.3",
            "publishedAt": "2026-06-01T00:00:00Z",
            "contracts": [
              { "network": "futurenet", "type": "anarchy", "id": "FUTURE..." },
              { "network": "testnet",   "type": "anarchy", "id": "KEEP..." }
            ]
          }]
        }
        """
        let manifest = try GitHubReleasesContractsManifestFetcher.decodeFiltering(Data(json.utf8))
        XCTAssertEqual(manifest.releases[0].contracts.count, 1, "futurenet entry must be silently dropped")
        XCTAssertEqual(manifest.releases[0].contracts[0].id, "KEEP...")
    }

    func test_decodeFiltering_dropsUnknownGovernanceType() throws {
        let json = """
        {
          "version": 1,
          "releases": [{
            "release": "v0.0.3",
            "publishedAt": "2026-06-01T00:00:00Z",
            "contracts": [
              { "network": "testnet", "type": "monarchy", "id": "MONARCH..." },
              { "network": "testnet", "type": "anarchy",  "id": "KEEP..." }
            ]
          }]
        }
        """
        let manifest = try GitHubReleasesContractsManifestFetcher.decodeFiltering(Data(json.utf8))
        XCTAssertEqual(manifest.releases[0].contracts.count, 1, "monarchy entry must be silently dropped")
    }

    // MARK: - error paths

    func test_decodeFiltering_throwsOnMalformedJSON() {
        XCTAssertThrowsError(
            try GitHubReleasesContractsManifestFetcher.decodeFiltering(Data("not json".utf8))
        ) { error in
            guard case ContractsManifestFetchError.malformedDocument = error else {
                return XCTFail("expected malformedDocument, got \(error)")
            }
        }
    }

    func test_decodeFiltering_throwsOnMissingVersionField() {
        let json = #"{"releases": []}"#
        XCTAssertThrowsError(
            try GitHubReleasesContractsManifestFetcher.decodeFiltering(Data(json.utf8))
        )
    }

    // MARK: - default URL

    func test_defaultURL_pointsAtGitHubReleasesLatestDownload() {
        XCTAssertEqual(
            GitHubReleasesContractsManifestFetcher.defaultURL.absoluteString,
            "https://github.com/onymchat/onym-contracts/releases/latest/download/contracts-manifest.json",
            "Renaming this URL silently breaks the prepopulation flow on every install"
        )
    }

    // MARK: - Fixture

    private static let fixtureJSON = """
    {
      "version": 1,
      "releases": [
        {
          "release": "v0.0.2",
          "publishedAt": "2026-05-01T15:29:00Z",
          "contracts": [
            { "network": "testnet", "type": "anarchy",   "id": "CDWYYK...RO2UMV" },
            { "network": "testnet", "type": "democracy", "id": "CBEBQM...ZPHIAC" },
            { "network": "testnet", "type": "oligarchy", "id": "CBHY24...J46COU" },
            { "network": "testnet", "type": "oneonone",  "id": "CAHXGZ...FO6OEB" },
            { "network": "testnet", "type": "tyranny",   "id": "CC6Y2F...45CFO3" }
          ]
        },
        {
          "release": "v0.0.1",
          "publishedAt": "2026-05-01T11:43:00Z",
          "contracts": [
            { "network": "testnet", "type": "anarchy",   "id": "CDSIJT...3RQ5B5" },
            { "network": "testnet", "type": "democracy", "id": "CBYHYJ...PGGYIX" },
            { "network": "testnet", "type": "oligarchy", "id": "CDCX2K...FEKM5W" },
            { "network": "testnet", "type": "oneonone",  "id": "CBTXK4...MQYJI3" },
            { "network": "testnet", "type": "tyranny",   "id": "CD2RTY...KCL447" }
          ]
        }
      ]
    }
    """
}
