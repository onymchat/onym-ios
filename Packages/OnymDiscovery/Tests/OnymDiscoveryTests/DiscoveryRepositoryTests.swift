import CryptoKit
import Foundation
import XCTest
@testable import OnymDiscovery

/// Fixture-serving fake fetcher: bytes by URL, no parsing.
private struct FakeFetcher: DiscoveryFetching {
    let responses: [URL: Data]

    func fetchProviderManifest(url: URL) async throws -> Data {
        guard let data = responses[url] else { throw DiscoveryFetchError.badStatus(404) }
        return data
    }

    func fetchSnapshot(url: URL) async throws -> Data {
        guard let data = responses[url] else { throw DiscoveryFetchError.badStatus(404) }
        return data
    }
}

/// In-memory store; no UserDefaults so tests stay hermetic.
private final class MemoryStore: DiscoveryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: DiscoverySourcesConfiguration = .empty
    private var snapshots: [String: Data] = [:]

    func loadConfiguration() -> DiscoverySourcesConfiguration {
        lock.withLock { configuration }
    }

    func saveConfiguration(_ configuration: DiscoverySourcesConfiguration) {
        lock.withLock { self.configuration = configuration }
    }

    func loadRetainedSnapshot(providerId: String, catalogId: String) -> Data? {
        lock.withLock { snapshots[providerId + "|" + catalogId] }
    }

    func saveRetainedSnapshot(_ raw: Data, providerId: String, catalogId: String) {
        lock.withLock { snapshots[providerId + "|" + catalogId] = raw }
    }

    func removeRetainedSnapshots(providerId: String) {
        lock.withLock {
            snapshots = snapshots.filter { !$0.key.hasPrefix(providerId + "|") }
        }
    }

    /// Every stored (providerId|catalogId) key — for orphan assertions.
    var storedSnapshotKeys: [String] {
        lock.withLock { Array(snapshots.keys) }
    }
}

/// Builds documents signed with the conformance fixtures' deterministic
/// operator seed (`onym-discovery` `tests/conformance.rs` `SEED_HEX`),
/// for repository-behavior tests that need document shapes the
/// byte-pinned fixture set does not carry (e.g. a two-catalog
/// manifest). Conformance tests keep using the pinned fixture bytes.
private enum SignedFixtureFactory {
    static let seedHex = String(repeating: "07", count: 32)

    static var operatorKeyHex: String {
        let key = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(lowercaseHex: seedHex)!
        )
        return key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// Re-serialize `object` with a fresh signature over its §3
    /// canonical bytes.
    static func resign(_ object: [String: Any]) throws -> Data {
        var object = object
        object["signature"] = ""
        let unsigned = try JSONSerialization.data(withJSONObject: object)
        let signingBytes = try DiscoveryCanonical.signingBytes(of: unsigned)
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(lowercaseHex: seedHex)!
        )
        object["signature"] = try key.signature(for: signingBytes).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The pinned `provider-manifest.json` fixture with a second
    /// catalog descriptor appended, re-signed.
    static func twoCatalogManifest(
        secondCatalogId: String,
        secondSnapshotURL: String
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Fixture.bytes("provider-manifest.json"))
                as? [String: Any]
        )
        var catalogs = try XCTUnwrap(object["catalogs"] as? [[String: Any]])
        var second = try XCTUnwrap(catalogs.first)
        second["catalogId"] = secondCatalogId
        second["snapshot"] = secondSnapshotURL
        catalogs.append(second)
        object["catalogs"] = catalogs
        return try resign(object)
    }
}

final class DiscoveryRepositoryTests: XCTestCase {
    private let manifestURL = URL(string: "https://discovery.onym.app/manifest.json")!
    private let snapshotURL = URL(string: "https://discovery.onym.app/catalogs/public-all-seats.json")!
    private let providerId = "onym:component:onym-discovery"

    private func pinnedConfiguration() -> DiscoverySourcesConfiguration {
        DiscoverySourcesConfiguration(
            sources: [DiscoverySource(
                providerId: providerId,
                userLabel: "Onym Discovery",
                manifestURL: manifestURL,
                pinnedOperatorKeyHex: Fixture.operatorKeyHex,
                addedAt: Fixture.now
            )],
            removedDefaultProviderIds: [],
            hasUserInteracted: true
        )
    }

    func testRefreshBuildsAttributedAggregateFromFixtures() async throws {
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let fetcher = FakeFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.refresh()
        let state = await repository.currentState()

        XCTAssertEqual(state.fetchStatus, .success)
        XCTAssertEqual(state.aggregate.count, 1)
        let attributed = try XCTUnwrap(state.aggregate.first)
        XCTAssertEqual(attributed.entry.componentId, "onym:component:onym-courier")
        XCTAssertEqual(attributed.source.providerId, providerId)
        XCTAssertEqual(attributed.source.sourceLabel, "Onym Discovery")
        XCTAssertEqual(attributed.source.catalogId, "public-all-seats")
        XCTAssertEqual(attributed.source.relationship, "common-owner")
        XCTAssertEqual(attributed.source.placement, "policy-ranked")
        let s1 = try Fixture.bytes("snapshot-1.json")
        XCTAssertEqual(attributed.source.snapshotDigest, DiscoveryFormat.sha256Digest(of: s1))
        XCTAssertNil(state.sources.first?.lastError)

        // Local seat-type filtering.
        let transport = await repository.entries(seatType: "transport.message")
        XCTAssertEqual(transport.count, 1)
        let notary = await repository.entries(seatType: "notary")
        XCTAssertTrue(notary.isEmpty)
    }

    func testChainAdvancesAcrossRefreshesAndRollbackIsSurfaced() async throws {
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let manifest = try Fixture.bytes("provider-manifest.json")

        // Refresh 1 accepts snapshot 1; refresh 2 accepts snapshot 2.
        for name in ["snapshot-1.json", "snapshot-2.json"] {
            let fetcher = FakeFetcher(responses: [
                manifestURL: manifest,
                snapshotURL: try Fixture.bytes(name),
            ])
            let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }
            await repository.refresh()
            let state = await repository.currentState()
            XCTAssertNil(state.sources.first?.lastError, name)
        }

        // A rollback to snapshot 1 must fail and surface on the source,
        // while the retained snapshot-2 aggregate stays available.
        let rollbackFetcher = FakeFetcher(responses: [
            manifestURL: manifest,
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: rollbackFetcher, store: store) { Fixture.now }
        await repository.refresh()
        let state = await repository.currentState()

        let sourceError = try XCTUnwrap(state.sources.first?.lastError)
        XCTAssertTrue(sourceError.contains("rejected"), sourceError)
        XCTAssertEqual(state.aggregate.count, 1, "retained snapshot 2 keeps serving offline")
        XCTAssertEqual(
            state.sources.first?.source.lastAccepted["public-all-seats"]?.sequence, 2,
            "rollback must not regress the accepted sequence"
        )
    }

    func testRefreshRejectsManifestForDifferentProviderId() async throws {
        // §6 refresh identity match: the pinned source's URL now
        // serves a (valid, correctly signed) manifest for a different
        // providerId — provider_manifest_invalid, surfaced on the
        // source, nothing accepted.
        let store = MemoryStore()
        store.saveConfiguration(DiscoverySourcesConfiguration(
            sources: [DiscoverySource(
                providerId: "onym:component:some-other-provider",
                userLabel: "Other",
                manifestURL: manifestURL,
                pinnedOperatorKeyHex: Fixture.operatorKeyHex,
                addedAt: Fixture.now
            )],
            removedDefaultProviderIds: [],
            hasUserInteracted: true
        ))
        let fetcher = FakeFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.refresh()
        let state = await repository.currentState()

        let sourceError = try XCTUnwrap(state.sources.first?.lastError)
        XCTAssertTrue(sourceError.contains("rejected"), sourceError)
        XCTAssertTrue(state.aggregate.isEmpty, "identity mismatch must contribute nothing")
    }

    func testStartSeedsDefaultOnceAndRemovedDefaultNeverReturns() async throws {
        let store = MemoryStore()
        let fetcher = FakeFetcher(responses: [:])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.start()
        var state = await repository.currentState()
        XCTAssertEqual(state.sources.map(\.source.providerId), [providerId])
        // Seeded default is unpinned → skipped by refresh, no error.
        XCTAssertNil(state.sources.first?.lastError)

        // Removing it is durable...
        await repository.removeSource(providerId: providerId)
        state = await repository.currentState()
        XCTAssertTrue(state.sources.isEmpty)
        XCTAssertTrue(store.loadConfiguration().removedDefaultProviderIds.contains(providerId))

        // ...even across a fresh start on the persisted configuration.
        let second = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }
        await second.start()
        let secondState = await second.currentState()
        XCTAssertTrue(secondState.sources.isEmpty, "a removed default must never silently return")
    }

    func testAddSourcePreviewDoesNotPinUntilConfirmed() async throws {
        let store = MemoryStore()
        let fetcher = FakeFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        let preview = try await repository.addSource(manifestURL: manifestURL)
        XCTAssertEqual(preview.providerId, providerId)
        XCTAssertEqual(preview.operatorKeyFingerprint, "ea4a 6c63 e29c 520a")
        XCTAssertTrue(store.loadConfiguration().sources.isEmpty, "preview must not persist")

        await repository.confirmAddSource(preview)
        let saved = store.loadConfiguration()
        XCTAssertEqual(saved.sources.count, 1)
        XCTAssertEqual(saved.sources.first?.pinnedOperatorKeyHex, Fixture.operatorKeyHex)
        XCTAssertTrue(saved.hasUserInteracted)
    }

    func testPartialCatalogFailureKeepsEarlierCatalogsAcceptance() async throws {
        // Two catalogs; the first's snapshot verifies, the second's
        // fetch 404s. The failure must surface on the source WITHOUT
        // discarding the first catalog's accepted record — the next
        // refresh's chain check depends on it.
        XCTAssertEqual(
            SignedFixtureFactory.operatorKeyHex, Fixture.operatorKeyHex,
            "factory seed must derive the fixtures' operator key"
        )
        let betaURL = URL(string: "https://discovery.onym.app/catalogs/beta-seats.json")!
        let manifest = try SignedFixtureFactory.twoCatalogManifest(
            secondCatalogId: "beta-seats",
            secondSnapshotURL: betaURL.absoluteString
        )
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let fetcher = FakeFetcher(responses: [
            manifestURL: manifest,
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
            // betaURL absent → 404 from the fake.
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.refresh()
        let state = await repository.currentState()

        let source = try XCTUnwrap(state.sources.first)
        XCTAssertNotNil(source.lastError, "the failing catalog must surface on the source")
        XCTAssertEqual(
            source.source.lastAccepted["public-all-seats"]?.sequence, 1,
            "the accepted catalog's record must be persisted despite the sibling failure"
        )
        XCTAssertNil(source.source.lastAccepted["beta-seats"])
        XCTAssertEqual(state.aggregate.count, 1, "the accepted catalog keeps serving")

        // And the persisted record feeds the next refresh's chain
        // check: snapshot 2 must verify as the successor, not as a
        // first acceptance.
        let fetcher2 = FakeFetcher(responses: [
            manifestURL: manifest,
            snapshotURL: try Fixture.bytes("snapshot-2.json"),
        ])
        let second = DiscoveryRepository(fetcher: fetcher2, store: store) { Fixture.now }
        await second.refresh()
        let secondState = await second.currentState()
        XCTAssertEqual(
            secondState.sources.first?.source.lastAccepted["public-all-seats"]?.sequence, 2
        )
    }

    func testRemoveSourcePurgesOrphanedSnapshotBlobs() async throws {
        // A blob the store retains but lastAccepted no longer lists
        // (dropped catalog / partial refresh) must not survive removal
        // and poison a re-add.
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        store.saveRetainedSnapshot(
            Data("{\"stale\":true}".utf8),
            providerId: providerId,
            catalogId: "orphaned-catalog"
        )
        let repository = DiscoveryRepository(fetcher: FakeFetcher(responses: [:]), store: store) { Fixture.now }

        await repository.removeSource(providerId: providerId)

        XCTAssertTrue(
            store.storedSnapshotKeys.filter { $0.hasPrefix(providerId + "|") }.isEmpty,
            "removal must purge every retained blob of the provider, orphans included"
        )
    }
}
