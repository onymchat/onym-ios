import XCTest
@testable import OnymIOS

/// Time-based expiry contract for `IntroKeyStore` (issue #111).
/// An entry older than `IntroKeyEntry.lifetime` is treated as if it
/// were revoked: `find` returns nil, `listForOwner` and the entries
/// stream omit it, and storage is lazy-purged so the
/// `IntroInboxPump` reconciler can cancel its relayer subscription.
final class IntroKeyStoreExpiryTests: XCTestCase {

    private let alice = IdentityID("11111111-1111-1111-1111-111111111111")!
    private let sampleGroupId = Data(repeating: 0x42, count: 32)

    private func entry(seed: UInt8, createdAt: Date) -> IntroKeyEntry {
        IntroKeyEntry(
            introPublicKey: Data(repeating: seed, count: 32),
            introPrivateKey: Data(repeating: seed &+ 1, count: 32),
            ownerIdentityID: alice,
            groupId: sampleGroupId,
            createdAt: createdAt
        )
    }

    func test_find_returnsNil_forEntryOlderThanLifetime() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryIntroKeyStore(now: { now })
        let stale = entry(
            seed: 0x10,
            createdAt: now.addingTimeInterval(-IntroKeyEntry.lifetime - 1)
        )
        await store.save(stale)

        let hit = await store.find(introPublicKey: stale.introPublicKey)
        XCTAssertNil(hit, "expired intro key must not be findable")
    }

    func test_find_returnsEntry_atLifetimeBoundary_minusOne() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryIntroKeyStore(now: { now })
        let fresh = entry(
            seed: 0x11,
            createdAt: now.addingTimeInterval(-IntroKeyEntry.lifetime + 1)
        )
        await store.save(fresh)

        let hit = await store.find(introPublicKey: fresh.introPublicKey)
        XCTAssertNotNil(hit, "entry one second under lifetime must still be honored")
    }

    func test_listForOwner_omitsExpiredEntries_keepsFresh() async {
        // Save two entries while both are fresh, then advance the
        // clock so only one crosses the expiry threshold. Exercises
        // the read-side filter, not just the purge-on-save path.
        let clock = MovableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let store = InMemoryIntroKeyStore(now: clock.read)
        let older = entry(seed: 0x10, createdAt: clock.now)
        await store.save(older)
        clock.advance(by: IntroKeyEntry.lifetime - 60)
        let newer = entry(seed: 0x20, createdAt: clock.now)
        await store.save(newer)
        clock.advance(by: 120)  // older is now expired, newer is not.

        let list = await store.listForOwner(alice)
        XCTAssertEqual(list.map(\.introPublicKey), [newer.introPublicKey])
    }

    func test_entriesStream_reEmits_whenLazyPurgeDropsRows() async throws {
        // Clock starts inside the lifetime window so the seeded entry
        // is initially live, then advances past expiry so a read
        // triggers the lazy purge and the stream re-emits an empty
        // snapshot — that's what `IntroInboxPump` needs in order to
        // cancel the relayer subscription.
        let clock = MovableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let store = InMemoryIntroKeyStore(now: clock.read)
        let staleSoon = entry(seed: 0x30, createdAt: clock.now)
        await store.save(staleSoon)

        let collector = SnapshotCollector()
        let task = Task {
            for await snapshot in store.entriesStream(forOwner: alice) {
                await collector.append(snapshot.map(\.introPublicKey))
                if await collector.count >= 2 { break }
            }
        }

        try await waitFor { await collector.count >= 1 }
        clock.advance(by: IntroKeyEntry.lifetime + 1)
        _ = await store.listForOwner(alice)

        try await waitFor { await collector.count >= 2 }
        task.cancel()

        let emissions = await collector.snapshots
        XCTAssertEqual(emissions.first, [staleSoon.introPublicKey])
        XCTAssertEqual(emissions.last, [])
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.02,
        _ predicate: @Sendable @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("waitFor predicate never became true within \(timeout)s",
                file: file, line: line)
    }
}

private actor SnapshotCollector {
    private(set) var snapshots: [[Data]] = []
    var count: Int { snapshots.count }
    func append(_ snapshot: [Data]) { snapshots.append(snapshot) }
}

/// Minimal mutable clock for time-travel tests. Production code
/// injects `Date.init`; tests can advance the clock to cross the
/// 24h expiry boundary without sleeping.
private final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { self.current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    var read: @Sendable () -> Date {
        { [weak self] in self?.now ?? Date() }
    }
}
