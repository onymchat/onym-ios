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

    func removeRetainedSnapshots(providerId: String, catalogIds: [String]) {
        lock.withLock {
            for catalogId in catalogIds {
                snapshots.removeValue(forKey: providerId + "|" + catalogId)
            }
        }
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
}
