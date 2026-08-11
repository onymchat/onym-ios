import XCTest
@testable import OnymIOS
import OnymFoundation
@testable import OnymGroup

/// Join requests used to live in memory only — a force-quit dropped them
/// and the joiner had to re-share. Now that the request renders as a row
/// inside the founder's chat thread, it has to survive a relaunch like
/// any other message would.
final class SwiftDataIntroRequestStoreTests: XCTestCase {

    func test_recordThenCurrent_roundTrips() async {
        let store = SwiftDataIntroRequestStore.inMemory()
        let request = makeRequest(id: "evt-1")

        let inserted = await store.record(request)
        XCTAssertTrue(inserted)

        let current = await store.current()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.id, "evt-1")
        XCTAssertEqual(current.first?.targetIntroPublicKey, request.targetIntroPublicKey)
    }

    /// Every relay reconnect replays the inbox, so a repeat of the same
    /// Nostr event id is the common path, not an edge case.
    func test_record_dedupesOnEventID() async {
        let store = SwiftDataIntroRequestStore.inMemory()

        let first = await store.record(makeRequest(id: "evt-dup"))
        let second = await store.record(makeRequest(id: "evt-dup"))
        XCTAssertTrue(first)
        XCTAssertFalse(second, "a replayed event id must not insert a second row")

        let current = await store.current()
        XCTAssertEqual(current.count, 1)
    }

    func test_consume_removesTheRequest() async {
        let store = SwiftDataIntroRequestStore.inMemory()
        _ = await store.record(makeRequest(id: "evt-a"))
        _ = await store.record(makeRequest(id: "evt-b"))

        await store.consume(id: "evt-a")

        let current = await store.current()
        XCTAssertEqual(current.map(\.id), ["evt-b"])
    }

    func test_current_isNewestFirst() async {
        let store = SwiftDataIntroRequestStore.inMemory()
        let now = Date()
        _ = await store.record(
            makeRequest(id: "old", receivedAt: now.addingTimeInterval(-3600))
        )
        _ = await store.record(
            makeRequest(id: "new", receivedAt: now.addingTimeInterval(-60))
        )

        let current = await store.current()
        XCTAssertEqual(current.map(\.id), ["new", "old"])
    }

    /// A new subscriber must see what's already on disk — that replay is
    /// what puts a restored request back into the thread on a cold
    /// launch, without waiting for a fresh relay delivery.
    func test_requestsStream_replaysStoredRequestsOnSubscribe() async throws {
        let store = SwiftDataIntroRequestStore.inMemory()
        _ = await store.record(makeRequest(id: "evt-replay"))

        var iterator = store.requests.makeAsyncIterator()
        let replayed = await iterator.next()

        XCTAssertEqual(replayed?.map(\.id), ["evt-replay"])
    }

    /// Persistence closed the "force-quit loses the request" hole but
    /// opened a slower one: a request whose group was deleted locally can
    /// no longer be rendered by any surface (the old cross-group modal is
    /// gone), so nothing ever calls `consume` on it. Retention is what
    /// keeps those from accumulating on disk forever.
    func test_requestsOlderThanRetention_areDropped() async {
        let store = SwiftDataIntroRequestStore.inMemory()
        _ = await store.record(makeRequest(id: "evt-stale"))

        // Advance past the window rather than back-dating the row: the
        // clock this measures is the store's own, stamped at `record`.
        await store.pruneExpired(
            now: Date().addingTimeInterval(SwiftDataIntroRequestStore.retention + 60)
        )

        let current = await store.current()
        XCTAssertTrue(current.isEmpty, "a request past the retention window must be swept")
    }

    func test_requestJustInsideRetention_isKept() async {
        let store = SwiftDataIntroRequestStore.inMemory()
        _ = await store.record(makeRequest(id: "evt-edge"))

        await store.pruneExpired(
            now: Date().addingTimeInterval(SwiftDataIntroRequestStore.retention - 3600)
        )

        let current = await store.current()
        XCTAssertEqual(current.map(\.id), ["evt-edge"])
    }

    /// Retention must not read `receivedAt`.
    ///
    /// That timestamp comes from the Nostr event's `ms` tag, which the
    /// *joiner* writes — so it is a claim, not an observation. Pruning on
    /// it meant a founder offline longer than the window had every
    /// replayed request swept on the first read, never seeing a request
    /// the joiner was still waiting on.
    func test_anOldSenderTimestampDoesNotAgeOutAFreshlySeenRequest() async {
        let store = SwiftDataIntroRequestStore.inMemory()
        let ancient = Date()
            .addingTimeInterval(-SwiftDataIntroRequestStore.retention * 10)

        _ = await store.record(makeRequest(id: "evt-backdated", receivedAt: ancient))

        let current = await store.current()
        XCTAssertEqual(
            current.map(\.id), ["evt-backdated"],
            "a request first seen just now is fresh, whatever the sender stamped on it"
        )
    }

    /// The other direction: a joiner stamping `ms` far in the future
    /// must not mint a row that outlives every sweep.
    func test_aFutureSenderTimestampStillExpires() async {
        let store = SwiftDataIntroRequestStore.inMemory()
        let farFuture = Date()
            .addingTimeInterval(SwiftDataIntroRequestStore.retention * 10)

        _ = await store.record(makeRequest(id: "evt-future", receivedAt: farFuture))
        await store.pruneExpired(
            now: Date().addingTimeInterval(SwiftDataIntroRequestStore.retention + 60)
        )

        let current = await store.current()
        XCTAssertTrue(current.isEmpty, "retention is on local first-sight, not the sender's claim")
    }

    // MARK: - Helpers

    /// Relative to now, not a fixed epoch: the store sweeps rows past
    /// `retention`, so a hardcoded past date would age out from under
    /// these tests as the wall clock moves.
    private func makeRequest(
        id: String,
        receivedAt: Date = Date()
    ) -> IntroRequest {
        IntroRequest(
            id: id,
            targetIntroPublicKey: Data(repeating: 0xAB, count: 32),
            payload: Data(repeating: 0xCD, count: 64),
            receivedAt: receivedAt
        )
    }
}
