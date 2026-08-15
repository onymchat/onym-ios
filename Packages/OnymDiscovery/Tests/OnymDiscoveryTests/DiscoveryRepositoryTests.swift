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

/// `FakeFetcher` whose responses can change between refresh passes.
private final class MutableFetcher: DiscoveryFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Data]

    init(responses: [URL: Data]) {
        self.responses = responses
    }

    func set(_ data: Data?, for url: URL) {
        lock.withLock { responses[url] = data }
    }

    private func serve(_ url: URL) throws -> Data {
        guard let data = lock.withLock({ responses[url] }) else {
            throw DiscoveryFetchError.badStatus(404)
        }
        return data
    }

    func fetchProviderManifest(url: URL) async throws -> Data { try serve(url) }
    func fetchSnapshot(url: URL) async throws -> Data { try serve(url) }
}

/// Suspends every manifest fetch until the gate opens, counting calls —
/// lets a test hold one refresh pass mid-flight deterministically.
private actor FetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class GatedFetcher: DiscoveryFetching, @unchecked Sendable {
    let gate = FetchGate()
    private let responses: [URL: Data]
    private let lock = NSLock()
    private var _manifestFetchCount = 0

    var manifestFetchCount: Int {
        lock.withLock { _manifestFetchCount }
    }

    init(responses: [URL: Data]) {
        self.responses = responses
    }

    func fetchProviderManifest(url: URL) async throws -> Data {
        lock.withLock { _manifestFetchCount += 1 }
        await gate.wait()
        guard let data = responses[url] else { throw DiscoveryFetchError.badStatus(404) }
        return data
    }

    func fetchSnapshot(url: URL) async throws -> Data {
        guard let data = responses[url] else { throw DiscoveryFetchError.badStatus(404) }
        return data
    }
}

/// Gates the manifest fetch of ONE url only — holds a full refresh
/// pass mid-flight on that source while other sources' fetches (an
/// added provider's) proceed.
private final class URLGatedFetcher: DiscoveryFetching, @unchecked Sendable {
    let gate = FetchGate()
    private let gatedURL: URL
    private let responses: [URL: Data]
    private let lock = NSLock()
    private var _gatedFetchCount = 0

    var gatedFetchCount: Int {
        lock.withLock { _gatedFetchCount }
    }

    init(gatedURL: URL, responses: [URL: Data]) {
        self.gatedURL = gatedURL
        self.responses = responses
    }

    private func serve(_ url: URL) throws -> Data {
        guard let data = responses[url] else { throw DiscoveryFetchError.badStatus(404) }
        return data
    }

    func fetchProviderManifest(url: URL) async throws -> Data {
        if url == gatedURL {
            lock.withLock { _gatedFetchCount += 1 }
            await gate.wait()
        }
        return try serve(url)
    }

    func fetchSnapshot(url: URL) async throws -> Data {
        try serve(url)
    }
}

/// Records every requested URL and 404s — for asserting a URL is
/// NEVER fetched (§7 validation must run before any network touch).
private final class RecordingFetcher: DiscoveryFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedURLs: [URL] = []

    var requestedURLs: [URL] {
        lock.withLock { _requestedURLs }
    }

    func fetchProviderManifest(url: URL) async throws -> Data {
        lock.withLock { _requestedURLs.append(url) }
        throw DiscoveryFetchError.badStatus(404)
    }

    func fetchSnapshot(url: URL) async throws -> Data {
        lock.withLock { _requestedURLs.append(url) }
        throw DiscoveryFetchError.badStatus(404)
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
    static func resign(_ object: [String: Any], seedHex: String = seedHex) throws -> Data {
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

    /// The pinned `provider-manifest.json` fixture re-signed under a
    /// DIFFERENT operator seed, `operator` updated to match — the
    /// key-rotation re-add case.
    static func manifest(operatorSeedHex: String) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Fixture.bytes("provider-manifest.json"))
                as? [String: Any]
        )
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(lowercaseHex: operatorSeedHex)!
        )
        let publicHex = key.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        object["operator"] = "onym:key:" + publicHex
        return try resign(object, seedHex: operatorSeedHex)
    }

    /// The pinned `provider-manifest.json` fixture with its single
    /// catalog's `seatTypes` replaced, re-signed.
    static func manifest(catalogSeatTypes: [String]) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Fixture.bytes("provider-manifest.json"))
                as? [String: Any]
        )
        var catalogs = try XCTUnwrap(object["catalogs"] as? [[String: Any]])
        catalogs[0]["seatTypes"] = catalogSeatTypes
        object["catalogs"] = catalogs
        return try resign(object)
    }

    /// The pinned `snapshot-1.json` fixture with its single entry's
    /// `seatType` replaced, re-signed.
    static func snapshot(entrySeatType: String) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Fixture.bytes("snapshot-1.json"))
                as? [String: Any]
        )
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0]["seatType"] = entrySeatType
        object["entries"] = entries
        return try resign(object)
    }

    /// The pinned `provider-manifest.json` fixture re-published under
    /// a different providerId (and snapshot URL), re-signed — a second,
    /// independent provider for multi-source tests.
    static func manifest(providerId: String, snapshotURL: String) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Fixture.bytes("provider-manifest.json"))
                as? [String: Any]
        )
        object["providerId"] = providerId
        var catalogs = try XCTUnwrap(object["catalogs"] as? [[String: Any]])
        catalogs[0]["snapshot"] = snapshotURL
        object["catalogs"] = catalogs
        return try resign(object)
    }

    /// The pinned `snapshot-1.json` fixture re-published under a
    /// different providerId, re-signed.
    static func snapshot(providerId: String) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Fixture.bytes("snapshot-1.json"))
                as? [String: Any]
        )
        object["providerId"] = providerId
        return try resign(object)
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

    /// Re-confirming an ALREADY-configured provider (the seeded
    /// default's TOFU confirm, or a re-confirm through the add sheet)
    /// must be an in-place update: the per-catalog `lastAccepted`
    /// chain state carries forward — resetting it would let the next
    /// refresh accept an older snapshot as if the chain never advanced
    /// (rollback laundering) — and the user's label survives.
    func testReconfirmExistingSourceKeepsChainStateAndLabel() async throws {
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let manifest = try Fixture.bytes("provider-manifest.json")

        // Advance the chain to snapshot 2.
        for name in ["snapshot-1.json", "snapshot-2.json"] {
            let fetcher = FakeFetcher(responses: [
                manifestURL: manifest,
                snapshotURL: try Fixture.bytes(name),
            ])
            let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }
            await repository.refresh()
        }

        // Re-confirm the same provider through the add-source path,
        // against a server now serving the OLD snapshot 1.
        let fetcher = FakeFetcher(responses: [
            manifestURL: manifest,
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }
        let preview = try await repository.addSource(manifestURL: manifestURL)
        await repository.confirmAddSource(preview)

        let saved = try XCTUnwrap(store.loadConfiguration().sources.first)
        XCTAssertEqual(saved.userLabel, "Onym Discovery",
                       "in-place confirm must keep the existing label, not reset to the URL host")
        XCTAssertEqual(saved.lastAccepted["public-all-seats"]?.sequence, 2,
                       "in-place confirm must carry the rollback chain forward")

        // And the carried-forward chain still rejects the rollback.
        await repository.refresh()
        let state = await repository.currentState()
        let sourceError = try XCTUnwrap(state.sources.first?.lastError)
        XCTAssertTrue(sourceError.contains("rejected"), sourceError)
        XCTAssertEqual(
            state.sources.first?.source.lastAccepted["public-all-seats"]?.sequence, 2,
            "the old snapshot must still be rejected as a rollback after re-confirm"
        )
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

    func testCrossCatalogSubstitutionNeverPersistsUnderTheExpectedCatalog() async throws {
        // Catalog A's (valid, correctly signed) snapshot served at
        // catalog B's URL: without the expected-catalogId binding it
        // would verify against A's descriptor and then persist and
        // attribute under B — clobbering B's retained chain state
        // permanently. It must be rejected with the substitution error
        // while A's own acceptance proceeds untouched.
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
            betaURL: try Fixture.bytes("snapshot-1.json"), // catalogId public-all-seats — substituted
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.refresh()
        let state = await repository.currentState()

        let source = try XCTUnwrap(state.sources.first)
        let error = try XCTUnwrap(source.lastError, "the substitution must surface on the source")
        XCTAssertTrue(error.contains("cross-catalog"), error)
        XCTAssertNil(
            source.source.lastAccepted["beta-seats"],
            "nothing may be persisted under the substituted catalog"
        )
        XCTAssertNil(
            store.loadRetainedSnapshot(providerId: providerId, catalogId: "beta-seats"),
            "no retained bytes may land under the substituted catalog"
        )
        XCTAssertEqual(
            source.source.lastAccepted["public-all-seats"]?.sequence, 1,
            "the legitimate catalog's acceptance stays untouched"
        )
    }

    func testOverlappingRefreshesCoalesceOntoOnePass() async throws {
        // refresh() is public and start() fires one concurrently: an
        // overlapping call must await the in-flight pass, not run a
        // second interleaved pass whose stale source copy could
        // regress accepted sequences.
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let fetcher = GatedFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        let first = Task { await repository.refresh() }
        // Wait until the first pass is suspended inside the manifest fetch.
        while fetcher.manifestFetchCount < 1 { await Task.yield() }
        let second = Task { await repository.refresh() }
        // Give the second caller room to reach the guard, then release.
        for _ in 0..<20 { await Task.yield() }
        await fetcher.gate.open()
        await first.value
        await second.value

        XCTAssertEqual(
            fetcher.manifestFetchCount, 1,
            "the overlapping refresh must coalesce onto the in-flight pass"
        )
        let state = await repository.currentState()
        XCTAssertEqual(state.fetchStatus, .success)
        XCTAssertEqual(state.sources.first?.source.lastAccepted["public-all-seats"]?.sequence, 1)
    }

    func testConfirmAddDuringInFlightRefreshRunsAFreshPassForTheAddedSource() async throws {
        // The reviewed race: `tappedConfirmAdd` persists the source
        // and then refreshes — but a full pass already in flight
        // captured its source list BEFORE the add, and a coalescing
        // `refresh()` would merely await it, so the new source would
        // never be fetched while the sheet says its catalogs are being
        // fetched now. `refreshSource(providerId:)` must run a fresh
        // targeted pass instead.
        let secondProviderId = "onym:component:second-provider"
        let secondManifestURL = URL(string: "https://second.example/manifest.json")!
        let secondSnapshotURL = URL(string: "https://second.example/catalogs/public-all-seats.json")!
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let fetcher = URLGatedFetcher(gatedURL: manifestURL, responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
            secondManifestURL: try SignedFixtureFactory.manifest(
                providerId: secondProviderId,
                snapshotURL: secondSnapshotURL.absoluteString
            ),
            secondSnapshotURL: try SignedFixtureFactory.snapshot(providerId: secondProviderId),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        // Hold a full pass mid-flight on the first source's manifest.
        let inFlight = Task { await repository.refresh() }
        while fetcher.gatedFetchCount < 1 { await Task.yield() }

        // Add + confirm the second provider while the pass is held.
        let preview = try await repository.addSource(manifestURL: secondManifestURL)
        await repository.confirmAddSource(preview)
        await repository.refreshSource(providerId: secondProviderId)

        var state = await repository.currentState()
        XCTAssertTrue(
            state.aggregate.contains { $0.source.providerId == secondProviderId },
            "the added source must be fetched by its own targeted pass, not skipped by the stale in-flight one"
        )
        XCTAssertNil(state.sources.first { $0.id == secondProviderId }?.lastError)

        // Release the held pass; both sources' results coexist.
        await fetcher.gate.open()
        await inFlight.value
        state = await repository.currentState()
        XCTAssertEqual(
            Set(state.aggregate.map(\.source.providerId)),
            [providerId, secondProviderId]
        )
        XCTAssertEqual(state.fetchStatus, .success)
    }

    func testTargetedRefreshDoesNotClobberGlobalFetchStatus() async throws {
        // `fetchStatus` reports the most recent FULL pass. A targeted
        // single-source refresh (the post-confirm fetch) succeeding
        // must not flip a full pass's `.failed` to `.success` — the
        // other sources are still failing; its own outcome belongs on
        // the source's status.
        let secondProviderId = "onym:component:second-provider"
        let secondManifestURL = URL(string: "https://second.example/manifest.json")!
        let secondSnapshotURL = URL(string: "https://second.example/catalogs/public-all-seats.json")!
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        // The configured default's URLs 404; only the second provider
        // resolves.
        let fetcher = FakeFetcher(responses: [
            secondManifestURL: try SignedFixtureFactory.manifest(
                providerId: secondProviderId,
                snapshotURL: secondSnapshotURL.absoluteString
            ),
            secondSnapshotURL: try SignedFixtureFactory.snapshot(providerId: secondProviderId),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.refresh()
        var state = await repository.currentState()
        guard case .failed = state.fetchStatus else {
            return XCTFail("expected the full pass to fail, got \(state.fetchStatus)")
        }

        let preview = try await repository.addSource(manifestURL: secondManifestURL)
        await repository.confirmAddSource(preview)
        await repository.refreshSource(providerId: secondProviderId)

        state = await repository.currentState()
        XCTAssertNil(state.sources.first { $0.id == secondProviderId }?.lastError)
        XCTAssertTrue(state.aggregate.contains { $0.source.providerId == secondProviderId })
        guard case .failed = state.fetchStatus else {
            return XCTFail(
                "a targeted refresh must not overwrite the full pass's status, got \(state.fetchStatus)"
            )
        }
    }

    func testConfirmAddSourcePublishesToSnapshotSubscribers() async throws {
        // `confirmAddSource` mutates configuration like every other
        // mutator, so it must rebuild + publish: a subscriber on
        // `snapshots` sees the new source immediately, not after some
        // unrelated refresh.
        let store = MemoryStore()
        let fetcher = FakeFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        var iterator = repository.snapshots.makeAsyncIterator()
        let replay = await iterator.next()
        XCTAssertEqual(replay?.sources.count, 0, "replay of the pre-add state")

        let preview = try await repository.addSource(manifestURL: manifestURL)
        await repository.confirmAddSource(preview)

        let published = await iterator.next()
        XCTAssertEqual(
            published?.sources.map(\.id), [providerId],
            "confirmAddSource must publish the mutated state to live subscribers"
        )
    }

    func testConfirmThenRefreshDuringInFlightPassRunsFollowUpPass() async throws {
        // The repository-level half of the reviewed race: a full pass
        // captured its source list before the add, so a `refresh()`
        // issued after `confirmAddSource` would coalesce onto that
        // stale pass and return `.success` without ever fetching the
        // new source. After joining, `refresh()` must detect the
        // uncovered source and run a follow-up pass.
        let secondProviderId = "onym:component:second-provider"
        let secondManifestURL = URL(string: "https://second.example/manifest.json")!
        let secondSnapshotURL = URL(string: "https://second.example/catalogs/public-all-seats.json")!
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let fetcher = URLGatedFetcher(gatedURL: manifestURL, responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
            secondManifestURL: try SignedFixtureFactory.manifest(
                providerId: secondProviderId,
                snapshotURL: secondSnapshotURL.absoluteString
            ),
            secondSnapshotURL: try SignedFixtureFactory.snapshot(providerId: secondProviderId),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        // Hold a full pass mid-flight on the first source's manifest.
        let inFlight = Task { await repository.refresh() }
        while fetcher.gatedFetchCount < 1 { await Task.yield() }

        // Add + confirm the second provider while the pass is held,
        // then ask for a plain refresh — the UI path with no targeted
        // refresh in between.
        let preview = try await repository.addSource(manifestURL: secondManifestURL)
        await repository.confirmAddSource(preview)
        let joined = Task { await repository.refresh() }

        await fetcher.gate.open()
        await inFlight.value
        await joined.value

        let state = await repository.currentState()
        XCTAssertEqual(
            Set(state.aggregate.map(\.source.providerId)),
            [providerId, secondProviderId],
            "the joined refresh must run a follow-up pass covering the source the stale pass never saw"
        )
        XCTAssertNil(state.sources.first { $0.id == secondProviderId }?.lastError)
        XCTAssertEqual(state.fetchStatus, .success)
    }

    func testAddSourceRejectsProfileURIRuleViolations() async throws {
        // §7 on the USER-SUPPLIED manifest URL, before any network
        // touch: http, IP literal, query, userinfo, and explicit port
        // are all rejected — and nothing is ever fetched.
        let store = MemoryStore()
        let fetcher = RecordingFetcher()
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        for bad in [
            "http://second.example/manifest.json",
            "https://192.168.1.1/manifest.json",
            "https://second.example/manifest.json?x=1",
            "https://second.example/manifest.json#frag",
            "https://user@second.example/manifest.json",
            "https://second.example:8443/manifest.json",
        ] {
            do {
                _ = try await repository.addSource(manifestURL: URL(string: bad)!)
                XCTFail("expected rejection for \(bad)")
            } catch let error as DiscoveryTrustError {
                guard case .providerManifestInvalid = error else {
                    return XCTFail("unexpected error \(error) for \(bad)")
                }
            }
        }
        XCTAssertTrue(
            fetcher.requestedURLs.isEmpty,
            "a rule-violating URL must never reach the fetcher"
        )
    }

    func testHostilePersistedManifestURLIsSurfacedNeverUsed() async throws {
        // §7 applies to the REHYDRATED configuration too: a persisted
        // source with a rule-violating manifest URL (hostile or
        // corrupted persistence — add-time validation would have
        // refused it) surfaces as that source's error state and is
        // excluded from fetching AND from the offline aggregate.
        let hostileURL = URL(string: "http://192.168.1.1/manifest.json")!
        let snapshot1 = try Fixture.bytes("snapshot-1.json")
        let store = MemoryStore()
        store.saveConfiguration(DiscoverySourcesConfiguration(
            sources: [DiscoverySource(
                providerId: providerId,
                userLabel: "Onym Discovery",
                manifestURL: hostileURL,
                pinnedOperatorKeyHex: Fixture.operatorKeyHex,
                addedAt: Fixture.now,
                isEnabled: true,
                lastAccepted: ["public-all-seats": AcceptedSnapshotRecord(
                    digest: DiscoveryFormat.sha256Digest(of: snapshot1),
                    sequence: 1,
                    acceptedAt: Fixture.now
                )]
            )],
            removedDefaultProviderIds: [],
            hasUserInteracted: true
        ))
        store.saveRetainedSnapshot(snapshot1, providerId: providerId, catalogId: "public-all-seats")
        let fetcher = RecordingFetcher()
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.start()
        await repository.refresh()
        let state = await repository.currentState()

        let sourceError = try XCTUnwrap(state.sources.first?.lastError)
        XCTAssertTrue(sourceError.contains("rejected"), sourceError)
        XCTAssertTrue(
            state.aggregate.isEmpty,
            "retained snapshots of a source with a rule-violating URL must not feed the offline aggregate"
        )
        XCTAssertTrue(
            fetcher.requestedURLs.isEmpty,
            "a rule-violating persisted URL must never be fetched"
        )
    }

    func testEntrySeatTypeFormatIsCheckedAtDecode() async throws {
        // §4.1 token form on the ENTRY side: a malformed seatType (or
        // the descriptor-only "*" wildcard) skips the entry — counted,
        // never passed through.
        let manifest = try DiscoveryTrust.verifyProviderManifest(
            raw: try Fixture.bytes("provider-manifest.json"),
            pinnedOperatorKeyHex: nil,
            now: Fixture.now
        )
        for bad in ["Transport.Message", "*", "trans port", String(repeating: "a", count: 65)] {
            let accepted = try DiscoveryTrust.verifySnapshot(
                raw: try SignedFixtureFactory.snapshot(entrySeatType: bad),
                manifest: manifest,
                expectedCatalogId: "public-all-seats",
                retained: nil,
                now: Fixture.now
            )
            XCTAssertTrue(accepted.snapshot.entries.isEmpty, "seatType \(bad) must skip the entry")
            XCTAssertEqual(accepted.snapshot.skippedEntryCount, 1, bad)
        }
    }

    func testEntrySeatTypeMustBeAdmittedByDeclaringDescriptor() async throws {
        // §4.1 cross-check: a catalog declaring `["notary"]` cannot
        // list `transport.message` entries — the violating entry is
        // skipped and counted. `"*"` (and an explicit match) admit.
        let snapshot1 = try Fixture.bytes("snapshot-1.json") // entry seatType transport.message
        func verified(_ seatTypes: [String]) throws -> SignedCatalogSnapshot {
            let manifest = try DiscoveryTrust.verifyProviderManifest(
                raw: try SignedFixtureFactory.manifest(catalogSeatTypes: seatTypes),
                pinnedOperatorKeyHex: nil,
                now: Fixture.now
            )
            return try DiscoveryTrust.verifySnapshot(
                raw: snapshot1,
                manifest: manifest,
                expectedCatalogId: "public-all-seats",
                retained: nil,
                now: Fixture.now
            )
        }

        let violating = try verified(["notary"])
        XCTAssertTrue(violating.snapshot.entries.isEmpty)
        XCTAssertEqual(violating.snapshot.skippedEntryCount, 1)

        let wildcard = try verified(["*"])
        XCTAssertEqual(wildcard.snapshot.entries.count, 1)
        XCTAssertEqual(wildcard.snapshot.skippedEntryCount, 0)

        let matching = try verified(["transport.message"])
        XCTAssertEqual(matching.snapshot.entries.count, 1)
        XCTAssertEqual(matching.snapshot.skippedEntryCount, 0)
    }

    func testSeatTypeViolationsStayOutOfAggregateAndOfflineRebuild() async throws {
        // Repository level: the violating entry never enters the
        // aggregate — not on refresh, and not on a later offline
        // rebuild from the retained bytes (which still contain it).
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let fetcher = FakeFetcher(responses: [
            manifestURL: try SignedFixtureFactory.manifest(catalogSeatTypes: ["notary"]),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.refresh()
        let state = await repository.currentState()
        XCTAssertNil(state.sources.first?.lastError)
        XCTAssertTrue(state.aggregate.isEmpty, "transport.message entry in a notary catalog must be skipped")
        XCTAssertFalse(
            state.sources.first?.notes.isEmpty ?? true,
            "the skipped entry must be counted and surfaced as a note"
        )

        // Fresh instance, no network: the offline rebuild applies the
        // same binding via the record's retained seatTypes.
        let offline = DiscoveryRepository(fetcher: FakeFetcher(responses: [:]), store: store) { Fixture.now }
        await offline.start()
        let offlineState = await offline.currentState()
        XCTAssertTrue(
            offlineState.aggregate.isEmpty,
            "the offline rebuild must not resurrect entries the refresh skipped"
        )
    }

    func testRotationReconfirmResetsChainAndPurgesRetainedBlobs() async throws {
        // Re-confirming the same providerId with a DIFFERENT operator
        // key is the rotation path — "re-adding the source as new". The
        // chain restarts (carrying it forward would wedge on the new
        // operator's sequence numbering), and the old identity's
        // retained blobs are purged rather than left orphaned.
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let fetcher = MutableFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }
        await repository.refresh()
        XCTAssertFalse(store.storedSnapshotKeys.isEmpty)

        let rotatedSeed = String(repeating: "0b", count: 32)
        fetcher.set(try SignedFixtureFactory.manifest(operatorSeedHex: rotatedSeed), for: manifestURL)
        let preview = try await repository.addSource(manifestURL: manifestURL)
        await repository.confirmAddSource(preview)

        let saved = try XCTUnwrap(store.loadConfiguration().sources.first)
        XCTAssertNotEqual(saved.pinnedOperatorKeyHex, Fixture.operatorKeyHex)
        XCTAssertTrue(saved.lastAccepted.isEmpty, "rotation re-add restarts the chain")
        XCTAssertTrue(
            store.storedSnapshotKeys.isEmpty,
            "the replaced identity's retained blobs must be purged, not orphaned"
        )
    }

    func testFreshConfirmPurgesOrphanedRetainedBlobs() async throws {
        // A genuinely fresh add (no configured source) also purges any
        // retained blobs under its providerId — e.g. an orphan a
        // mid-pass removal left behind.
        let store = MemoryStore()
        store.saveRetainedSnapshot(
            try Fixture.bytes("snapshot-1.json"),
            providerId: providerId,
            catalogId: "public-all-seats"
        )
        let fetcher = FakeFetcher(responses: [
            manifestURL: try Fixture.bytes("provider-manifest.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        let preview = try await repository.addSource(manifestURL: manifestURL)
        await repository.confirmAddSource(preview)

        XCTAssertTrue(
            store.storedSnapshotKeys.isEmpty,
            "a fresh confirm must start from a clean retained state"
        )
    }

    func testManifestStageFailureClearsStaleNotes() async throws {
        // Pass 1 accepts snapshot 1; pass 2 forward-jumps to snapshot 3
        // (producing a note); pass 3 fails at the manifest fetch. The
        // stale forward-jump note must not stay displayed next to the
        // new failure — notes are cleared at the top of the source
        // refresh, not only on the success path.
        let store = MemoryStore()
        store.saveConfiguration(pinnedConfiguration())
        let manifest = try Fixture.bytes("provider-manifest.json")
        let fetcher = MutableFetcher(responses: [
            manifestURL: manifest,
            snapshotURL: try Fixture.bytes("snapshot-1.json"),
        ])
        let repository = DiscoveryRepository(fetcher: fetcher, store: store) { Fixture.now }

        await repository.refresh()
        var state = await repository.currentState()
        XCTAssertEqual(state.sources.first?.notes, [])

        fetcher.set(try Fixture.bytes("snapshot-3.json"), for: snapshotURL)
        await repository.refresh()
        state = await repository.currentState()
        let jumpNote = try XCTUnwrap(state.sources.first?.notes.first)
        XCTAssertTrue(jumpNote.contains("could not be verified"), jumpNote)

        fetcher.set(nil, for: manifestURL) // manifest fetch now 404s
        await repository.refresh()
        state = await repository.currentState()
        XCTAssertNotNil(state.sources.first?.lastError)
        XCTAssertEqual(
            state.sources.first?.notes, [],
            "a manifest-stage failure must not display the previous pass's notes"
        )
    }

    func testAllSourcesUnpinnedSurfacesNeedsConfirmation() async throws {
        // Only an unpinned (seeded, unconfirmed) source: refresh must
        // not report a bare .success over a silently empty aggregate —
        // the source carries a needs-confirmation note and the status
        // says why nothing was fetched.
        let store = MemoryStore()
        let repository = DiscoveryRepository(fetcher: FakeFetcher(responses: [:]), store: store) { Fixture.now }
        await repository.start()
        // start() refreshes in the background; await a full pass so the
        // assertion isn't racing it.
        await repository.refresh()
        let state = await repository.currentState()

        XCTAssertEqual(state.sources.count, 1)
        XCTAssertNil(state.sources.first?.lastError)
        let note = try XCTUnwrap(state.sources.first?.notes.first)
        XCTAssertTrue(note.lowercased().contains("confirm"), note)
        guard case .failed(let message) = state.fetchStatus else {
            return XCTFail("expected a surfaced non-success status, got \(state.fetchStatus)")
        }
        XCTAssertTrue(message.lowercased().contains("confirm"), message)
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
