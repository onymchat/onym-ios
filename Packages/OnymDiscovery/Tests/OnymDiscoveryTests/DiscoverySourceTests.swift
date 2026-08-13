import Foundation
import XCTest
@testable import OnymDiscovery

final class DiscoverySourceTests: XCTestCase {
    func testConfigurationRoundTripsThroughCodable() throws {
        let source = DiscoverySource(
            providerId: "onym:component:onym-discovery",
            userLabel: "Onym Discovery",
            manifestURL: URL(string: "https://discovery.onym.app/manifest.json")!,
            pinnedOperatorKeyHex: Fixture.operatorKeyHex,
            addedAt: Fixture.now,
            isEnabled: false,
            lastAccepted: [
                "public-all-seats": AcceptedSnapshotRecord(
                    digest: "sha256:" + String(repeating: "9", count: 64),
                    sequence: 3,
                    acceptedAt: Fixture.now
                ),
            ]
        )
        let config = DiscoverySourcesConfiguration(
            sources: [source],
            removedDefaultProviderIds: ["onym:component:gone"],
            hasUserInteracted: true
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DiscoverySourcesConfiguration.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testBackwardCompatDecodingDefaultsNewerFields() throws {
        // A save from a build that predates removedDefaultProviderIds /
        // hasUserInteracted, and a source lacking isEnabled /
        // lastAccepted / addedAt: absence never re-seeds or disables.
        let legacy = Data("""
        {"sources":[{"providerId":"onym:component:x","userLabel":"X",\
        "manifestURL":"https://x.example/manifest.json",\
        "pinnedOperatorKeyHex":"\(Fixture.operatorKeyHex)"}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(DiscoverySourcesConfiguration.self, from: legacy)
        XCTAssertEqual(decoded.sources.count, 1)
        XCTAssertTrue(decoded.sources[0].isEnabled)
        XCTAssertEqual(decoded.sources[0].lastAccepted, [:])
        XCTAssertTrue(decoded.removedDefaultProviderIds.isEmpty)
        XCTAssertTrue(decoded.hasUserInteracted, "absence must decode as already-interacted")
    }

    func testFingerprintFormatsFirstSixteenHexCharsInGroupsOfFour() {
        XCTAssertEqual(
            DiscoverySource.fingerprint(ofKeyHex: Fixture.operatorKeyHex),
            "ea4a 6c63 e29c 520a"
        )
    }

    func testStoreRoundTripsConfigurationAndRetainedSnapshots() throws {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsDiscoveryStore(defaults: defaults)

        XCTAssertEqual(store.loadConfiguration(), .empty)
        let config = DiscoverySourcesConfiguration(
            sources: [.onymDefault],
            removedDefaultProviderIds: [],
            hasUserInteracted: true
        )
        store.saveConfiguration(config)
        XCTAssertEqual(store.loadConfiguration(), config)

        let raw = Data("{\"exact\":\"bytes\"}".utf8)
        store.saveRetainedSnapshot(raw, providerId: "onym:component:p", catalogId: "c")
        XCTAssertEqual(store.loadRetainedSnapshot(providerId: "onym:component:p", catalogId: "c"), raw)
        store.removeRetainedSnapshots(providerId: "onym:component:p", catalogIds: ["c"])
        XCTAssertNil(store.loadRetainedSnapshot(providerId: "onym:component:p", catalogId: "c"))
    }
}
