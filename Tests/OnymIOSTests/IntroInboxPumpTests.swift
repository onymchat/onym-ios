import XCTest
@testable import OnymIOS

/// Behavioral tests for `IntroInboxPump`. Mirrors
/// `IntroInboxPumpTest.kt` test-for-test. Uses the shared
/// `RecordingInboxTransport` pattern from
/// `InboxFanoutInteractorTests` (kept private to that file — we
/// duplicate a slimmer one here rather than refactoring two suites
/// in one PR).
final class IntroInboxPumpTests: XCTestCase {

    private let alice = IdentityID("11111111-1111-1111-1111-111111111111")!
    private let groupId = Data(repeating: 0x42, count: 32)

    private func entry(seed: UInt8) -> IntroKeyEntry {
        IntroKeyEntry(
            introPublicKey: Data(repeating: seed, count: 32),
            introPrivateKey: Data(repeating: seed &+ 1, count: 32),
            ownerIdentityID: alice,
            groupId: groupId,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Fake tag derivation — each pubkey gets the hex of its first
    /// 4 bytes as its tag. Doesn't have to match the production
    /// SHA-256 derivation; the pump only needs the mapping to be
    /// deterministic + the inverse uniquely recoverable.
    private static func fakeTag(_ pub: Data) -> TransportInboxID {
        TransportInboxID(rawValue: pub.prefix(4).map { String(format: "%02x", $0) }.joined())
    }

    func test_run_subscribesToEveryIntroPubInTheList() async throws {
        let transport = PumpRecordingInboxTransport()
        let store = InMemoryIntroRequestStore()
        let pump = IntroInboxPump(
            inboxTransport: transport,
            store: store,
            inboxTagFor: Self.fakeTag
        )

        let (entriesStream, cont) = AsyncStream.makeStream(of: [IntroKeyEntry].self)
        cont.yield([entry(seed: 0x10), entry(seed: 0x20)])

        let runTask = Task { await pump.run(entries: entriesStream) }
        try await waitFor { await transport.subscribed.count >= 2 }

        let live = await transport.subscribed
        XCTAssertEqual(
            Set(live),
            Set([
                Self.fakeTag(entry(seed: 0x10).introPublicKey),
                Self.fakeTag(entry(seed: 0x20).introPublicKey),
            ])
        )

        cont.finish()
        runTask.cancel()
    }

    func test_inboundOnTaggedInbox_recordedWithMatchingIntroPub() async throws {
        let transport = PumpRecordingInboxTransport()
        let store = InMemoryIntroRequestStore()
        let pump = IntroInboxPump(
            inboxTransport: transport,
            store: store,
            inboxTagFor: Self.fakeTag
        )

        let e = entry(seed: 0x10)
        let (entriesStream, cont) = AsyncStream.makeStream(of: [IntroKeyEntry].self)
        cont.yield([e])

        let runTask = Task { await pump.run(entries: entriesStream) }
        try await waitFor { await transport.subscribed.count >= 1 }

        let now = Date(timeIntervalSince1970: 1_700_000_500)
        await transport.inject(InboundInbox(
            inbox: Self.fakeTag(e.introPublicKey),
            payload: Data("request-bytes".utf8),
            receivedAt: now,
            messageID: "ev-1"
        ))

        try await waitFor { await store.current().count >= 1 }
        let recorded = await store.current()
        XCTAssertEqual(recorded.count, 1)
        // Every inbound is stamped with the introPub of the entry
        // whose tag it landed on. PR-4's approval interactor looks
        // up the privkey by this field.
        XCTAssertEqual(recorded.first?.targetIntroPublicKey, e.introPublicKey)
        XCTAssertEqual(recorded.first?.id, "ev-1")

        cont.finish()
        runTask.cancel()
    }

    func test_swappingTheListCancelsOldSubsAndStartsNewOnes() async throws {
        let transport = PumpRecordingInboxTransport()
        let store = InMemoryIntroRequestStore()
        let pump = IntroInboxPump(
            inboxTransport: transport,
            store: store,
            inboxTagFor: Self.fakeTag
        )

        let a = entry(seed: 0x10)
        let c = entry(seed: 0x30)
        let (entriesStream, cont) = AsyncStream.makeStream(of: [IntroKeyEntry].self)
        cont.yield([a])

        let runTask = Task { await pump.run(entries: entriesStream) }
        try await waitFor { await transport.subscribed.count >= 1 }

        cont.yield([c])
        try await waitFor { await transport.unsubscribed.contains(Self.fakeTag(a.introPublicKey)) }
        try await waitFor { await transport.subscribed.contains(Self.fakeTag(c.introPublicKey)) }

        cont.finish()
        runTask.cancel()
    }

    func test_emptyList_subscribesToNothing() async throws {
        let transport = PumpRecordingInboxTransport()
        let store = InMemoryIntroRequestStore()
        let pump = IntroInboxPump(
            inboxTransport: transport,
            store: store,
            inboxTagFor: Self.fakeTag
        )

        let (entriesStream, cont) = AsyncStream.makeStream(of: [IntroKeyEntry].self)
        cont.yield([])

        let runTask = Task { await pump.run(entries: entriesStream) }
        // Give a generous window to make sure no spurious subscribes
        // sneak in. 200ms is plenty for the actor reconciliation.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let count = await transport.subscribed.count
        XCTAssertEqual(count, 0, "empty entries → no subscriptions")

        cont.finish()
        runTask.cancel()
    }

    // MARK: - Helpers

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

// MARK: - Test doubles

private actor PumpRecordingInboxTransport: InboxTransport {
    private(set) var subscribed: [TransportInboxID] = []
    private(set) var unsubscribed: [TransportInboxID] = []
    private var continuations: [TransportInboxID: AsyncStream<InboundInbox>.Continuation] = [:]

    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}

    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        PublishReceipt(messageID: UUID().uuidString, acceptedBy: 1)
    }

    nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream { continuation in
            Task { await self.register(inbox: inbox, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.releaseContinuation(inbox: inbox) }
            }
        }
    }

    func unsubscribe(inbox: TransportInboxID) async {
        unsubscribed.append(inbox)
        continuations[inbox]?.finish()
        continuations.removeValue(forKey: inbox)
    }

    func inject(_ message: InboundInbox) {
        continuations[message.inbox]?.yield(message)
    }

    private func register(
        inbox: TransportInboxID,
        continuation: AsyncStream<InboundInbox>.Continuation
    ) {
        subscribed.append(inbox)
        continuations[inbox] = continuation
    }

    private func releaseContinuation(inbox: TransportInboxID) {
        continuations.removeValue(forKey: inbox)
    }
}
