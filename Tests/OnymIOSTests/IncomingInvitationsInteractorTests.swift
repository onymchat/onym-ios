import XCTest
@testable import OnymIOS

/// Pump tests for the seam-A → interactor → seam-B pattern. The
/// interactor itself owns no state, so these tests assert pump shape:
///
/// - every `InboundInbox` from the upstream `InboxTransport` becomes
///   one `recordIncoming` on the downstream repository,
/// - dedup at the repository layer holds when the upstream re-emits
///   the same `messageID` (relays often do — N-redundant relays will
///   each deliver the same event once),
/// - `Task.cancel()` exits the run loop and unsubscribes upstream.
///
/// Same fakes (`FakeInboxTransport` + `InMemoryInvitationStore`) will
/// drive future "transport-to-persistence" interactor tests.
final class IncomingInvitationsInteractorTests: XCTestCase {
    private var transport: FakeInboxTransport!
    private var store: InMemoryInvitationStore!
    private var repository: IncomingInvitationsRepository!
    private var interactor: IncomingInvitationsInteractor!

    private let inbox = TransportInboxID(rawValue: "inbox-abc")
    /// Stub identity that owns the inbox in this test surface. The
    /// interactor stamps `ownerIdentityID` on every persisted record;
    /// these tests don't exercise the multi-identity routing layer
    /// (covered by `IncomingInvitationsRepositoryTests` +
    /// `InvitationDecryptorTests`), so a single fixed ID is fine.
    private let ownerID = IdentityID()

    override func setUp() {
        super.setUp()
        transport = FakeInboxTransport()
        store = InMemoryInvitationStore()
        repository = IncomingInvitationsRepository(
            store: store,
            currentIdentityID: ownerID
        )
        interactor = IncomingInvitationsInteractor(
            inboxTransport: transport,
            repository: repository
        )
    }

    override func tearDown() {
        transport = nil
        store = nil
        repository = nil
        interactor = nil
        super.tearDown()
    }

    // MARK: - pump shape

    func test_oneInboundMessage_persistsOneInvitation() async throws {
        let task = Task { await interactor.run(inbox: inbox, ownerIdentityID: ownerID) }
        try await waitForSubscribe()

        await transport.emit(makeInbound(messageID: "evt-1", payload: Data("hello".utf8)))

        try await waitForStored(count: 1)
        await transport.finish()
        await task.value

        let stored = await store.list()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].id, "evt-1")
        XCTAssertEqual(stored[0].payload, Data("hello".utf8))
        XCTAssertEqual(stored[0].status, .pending)
    }

    func test_multipleInboundMessages_persistAllInOrder() async throws {
        let task = Task { await interactor.run(inbox: inbox, ownerIdentityID: ownerID) }
        try await waitForSubscribe()

        let now = Date()
        await transport.emit([
            makeInbound(messageID: "evt-1", receivedAt: now),
            makeInbound(messageID: "evt-2", receivedAt: now.addingTimeInterval(1)),
            makeInbound(messageID: "evt-3", receivedAt: now.addingTimeInterval(2)),
        ])

        try await waitForStored(count: 3)
        await transport.finish()
        await task.value

        let stored = await store.list()
        // store sorts by receivedAt desc — newest first
        XCTAssertEqual(stored.map(\.id), ["evt-3", "evt-2", "evt-1"])
    }

    func test_duplicateMessageID_dedupedAtRepository() async throws {
        let task = Task { await interactor.run(inbox: inbox, ownerIdentityID: ownerID) }
        try await waitForSubscribe()

        // Same messageID twice — simulates two redundant relays
        // delivering the same Nostr event.
        let payload = Data("hello".utf8)
        await transport.emit(makeInbound(messageID: "evt-dup", payload: payload))
        try await waitForStored(count: 1)
        await transport.emit(makeInbound(messageID: "evt-dup", payload: payload))
        // give the second emit a moment to be processed (nothing to wait for since
        // dedup is a no-op — sleep one scheduler tick)
        try await Task.sleep(for: .milliseconds(20))

        await transport.finish()
        await task.value

        let stored = await store.list()
        XCTAssertEqual(stored.count, 1, "second relay copy must dedup, not produce a second row")
    }

    // MARK: - cancellation

    func test_cancellation_exitsRunLoopAndUnsubscribes() async throws {
        let task = Task { await interactor.run(inbox: inbox, ownerIdentityID: ownerID) }
        try await waitForSubscribe()

        task.cancel()
        // Finish the upstream stream so the for-await loop's iterator
        // can return nil and the task can complete.
        await transport.finish()
        await task.value

        let unsubscribed = await transport.unsubscribedInboxes
        XCTAssertEqual(unsubscribed, [inbox],
                       "cancellation must propagate via AsyncStream.onTermination → unregister")
    }

    // MARK: - Helpers

    private func makeInbound(
        messageID: String,
        payload: Data = Data(),
        receivedAt: Date = Date()
    ) -> InboundInbox {
        InboundInbox(
            inbox: inbox,
            payload: payload,
            receivedAt: receivedAt,
            messageID: messageID
        )
    }

    /// Spin until the FakeInboxTransport reports a subscriber. Avoids
    /// races where the test emits before the pump has installed its
    /// continuation.
    private func waitForSubscribe(timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while await transport.subscribeCallCount == 0 {
            if Date() > deadline { XCTFail("interactor never subscribed within \(timeoutMs)ms"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Spin until the in-memory store has the expected row count.
    private func waitForStored(count: Int, timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while await store.list().count < count {
            if Date() > deadline {
                let actual = await store.list().count
                XCTFail("expected \(count) stored within \(timeoutMs)ms, got \(actual)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
