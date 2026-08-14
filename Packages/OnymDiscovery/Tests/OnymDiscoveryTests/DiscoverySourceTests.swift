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

    // MARK: - DefaultDiscoveryStore

    private func makeIsolatedStoreEnvironment() throws -> (UserDefaults, URL, () -> Void) {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-store-tests-\(UUID().uuidString)", isDirectory: true)
        return (defaults, directory, {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    func testStoreRoundTripsConfigurationAndRetainedSnapshots() throws {
        let (defaults, directory, cleanup) = try makeIsolatedStoreEnvironment()
        defer { cleanup() }
        let store = DefaultDiscoveryStore(defaults: defaults, snapshotsDirectory: directory)

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
        store.removeRetainedSnapshots(providerId: "onym:component:p")
        XCTAssertNil(store.loadRetainedSnapshot(providerId: "onym:component:p", catalogId: "c"))
    }

    func testStoreKeepsSnapshotBlobsOutOfUserDefaults() throws {
        // Snapshots are up to 1 MiB per catalog — they must land as
        // files, never in the defaults plist.
        let (defaults, directory, cleanup) = try makeIsolatedStoreEnvironment()
        defer { cleanup() }
        let store = DefaultDiscoveryStore(defaults: defaults, snapshotsDirectory: directory)

        store.saveRetainedSnapshot(
            Data("{\"a\":1}".utf8),
            providerId: "onym:component:p",
            catalogId: "c"
        )
        let snapshotKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("app.onym.ios.discovery.snapshot.") }
        XCTAssertTrue(snapshotKeys.isEmpty, "blob bytes must not be written to UserDefaults")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("onym:component:p")
                    .appendingPathComponent("c.json").path
            )
        )
    }

    func testStoreMigratesLegacyUserDefaultsSnapshotsToFiles() throws {
        let (defaults, directory, cleanup) = try makeIsolatedStoreEnvironment()
        defer { cleanup() }

        // A blob persisted by a pre-file-store build, keyed
        // <prefix><providerId>|<catalogId>.
        let raw = Data("{\"legacy\":\"bytes\"}".utf8)
        defaults.set(raw, forKey: "app.onym.ios.discovery.snapshot.onym:component:p|c")

        let store = DefaultDiscoveryStore(defaults: defaults, snapshotsDirectory: directory)
        XCTAssertEqual(
            store.loadRetainedSnapshot(providerId: "onym:component:p", catalogId: "c"),
            raw,
            "legacy blob must be readable through the file store after migration"
        )
        XCTAssertNil(
            defaults.data(forKey: "app.onym.ios.discovery.snapshot.onym:component:p|c"),
            "migration must remove the legacy defaults entry"
        )
    }

    func testRemoveRetainedSnapshotsIsPrefixWide() throws {
        // Removal must not depend on an enumerated catalog list:
        // orphaned blobs (catalogs the manifest later dropped, partial
        // refreshes) go too, so a re-add can never see stale bytes.
        let (defaults, directory, cleanup) = try makeIsolatedStoreEnvironment()
        defer { cleanup() }
        let store = DefaultDiscoveryStore(defaults: defaults, snapshotsDirectory: directory)

        store.saveRetainedSnapshot(Data("a".utf8), providerId: "onym:component:p", catalogId: "kept")
        store.saveRetainedSnapshot(Data("b".utf8), providerId: "onym:component:p", catalogId: "orphan")
        store.saveRetainedSnapshot(Data("c".utf8), providerId: "onym:component:other", catalogId: "kept")

        store.removeRetainedSnapshots(providerId: "onym:component:p")

        XCTAssertNil(store.loadRetainedSnapshot(providerId: "onym:component:p", catalogId: "kept"))
        XCTAssertNil(store.loadRetainedSnapshot(providerId: "onym:component:p", catalogId: "orphan"))
        XCTAssertEqual(
            store.loadRetainedSnapshot(providerId: "onym:component:other", catalogId: "kept"),
            Data("c".utf8),
            "other providers' blobs are untouched"
        )
    }
}
