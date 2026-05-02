import Foundation
@testable import OnymIOS

/// Test-controllable `InboxTransport`. Each `subscribe(inbox:)` call
/// returns an `AsyncStream` whose continuation is owned by the caller
/// of `emit` / `finish` — so a test can deterministically drive the
/// pump under test:
///
/// ```swift
/// let transport = FakeInboxTransport()
/// let interactor = IncomingInvitationsInteractor(
///     inboxTransport: transport,
///     repository: repo
/// )
/// let task = Task { await interactor.run(inbox: TransportInboxID(rawValue: "abc")) }
/// await transport.emit(.init(inbox: ..., payload: ..., receivedAt: ..., messageID: ...))
/// await transport.finish()
/// await task.value
/// ```
///
/// Tracks `connect` / `disconnect` / `unsubscribe` calls so tests can
/// assert the interactor cleans up properly. Reusable for any future
/// "InboxTransport-driven interactor" test.
actor FakeInboxTransport: InboxTransport {
    private var continuations: [TransportInboxID: AsyncStream<InboundInbox>.Continuation] = [:]

    private(set) var connectedEndpoints: [TransportEndpoint] = []
    private(set) var disconnectCallCount = 0
    private(set) var unsubscribedInboxes: [TransportInboxID] = []
    private(set) var subscribeCallCount = 0

    // MARK: - InboxTransport

    func connect(to endpoints: [TransportEndpoint]) async {
        connectedEndpoints.append(contentsOf: endpoints)
    }

    func disconnect() async {
        disconnectCallCount += 1
        for cont in continuations.values { cont.finish() }
        continuations.removeAll()
    }

    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        // Not exercised by the pump; tests asserting on send paths use a different fake.
        PublishReceipt(messageID: "fake-\(UUID().uuidString)", acceptedBy: 1)
    }

    nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream { continuation in
            Task { await self.register(inbox: inbox, continuation: continuation) }
            // Route stream termination through the public unsubscribe so
            // tests can observe it via `unsubscribedInboxes`. Matches
            // production NostrInboxTransport's onTermination path.
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(inbox: inbox) }
            }
        }
    }

    func unsubscribe(inbox: TransportInboxID) async {
        unsubscribedInboxes.append(inbox)
        continuations.removeValue(forKey: inbox)?.finish()
    }

    // MARK: - Test driver

    /// Push one `InboundInbox` to all subscribers of its inbox id.
    /// Yielding through the AsyncStream is synchronous; the awaiting
    /// `for await` loop on the consumer side resumes on the next
    /// scheduler tick.
    func emit(_ message: InboundInbox) {
        continuations[message.inbox]?.yield(message)
    }

    /// Convenience: emit a sequence in order.
    func emit(_ messages: [InboundInbox]) {
        for m in messages { emit(m) }
    }

    /// Finish all open subscriptions — the consumer's `for await` loop
    /// exits, the pump task completes. Use this to make tests
    /// deterministically reach `await task.value`.
    func finish() {
        for cont in continuations.values { cont.finish() }
        continuations.removeAll()
    }

    // MARK: - Private

    private func register(
        inbox: TransportInboxID,
        continuation: AsyncStream<InboundInbox>.Continuation
    ) {
        subscribeCallCount += 1
        continuations[inbox] = continuation
    }
}
