import XCTest
@testable import OnymIOS
import OnymFoundation
import OnymGroup

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
        _ = await store.record(
            makeRequest(id: "old", receivedAt: Date(timeIntervalSince1970: 1_000))
        )
        _ = await store.record(
            makeRequest(id: "new", receivedAt: Date(timeIntervalSince1970: 2_000))
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

    // MARK: - Helpers

    private func makeRequest(
        id: String,
        receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> IntroRequest {
        IntroRequest(
            id: id,
            targetIntroPublicKey: Data(repeating: 0xAB, count: 32),
            payload: Data(repeating: 0xCD, count: 64),
            receivedAt: receivedAt
        )
    }
}
