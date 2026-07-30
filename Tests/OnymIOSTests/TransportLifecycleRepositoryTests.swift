import XCTest
@testable import OnymIOS

/// PR-8 of the reconnect design: the transport's lifecycle belongs to
/// the repository layer, not the view tree. The repository owns connect
/// + every reconnect trigger (injected streams — no UIKit here), and the
/// presentation layer's ONLY contact with the transport is the
/// connection-state snapshot stream.
final class TransportLifecycleRepositoryTests: XCTestCase {
    private func makeSignals() -> (stream: AsyncStream<Void>, fire: () -> Void, finish: () -> Void) {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { continuation = $0 }
        let cont = continuation!
        return (stream, { cont.yield(()) }, { cont.finish() })
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("condition not met within \(timeout)s")
    }

    func test_start_connectsToEndpoints() async throws {
        let transport = FakeInboxTransport()
        let repo = TransportLifecycleRepository(
            transport: transport,
            foregroundSignals: makeSignals().stream,
            connectivitySignals: makeSignals().stream
        )
        let endpoint = TransportEndpoint(url: URL(string: "wss://relay.example")!)
        await repo.start(endpoints: [endpoint])

        let connected = await transport.connectedEndpoints
        XCTAssertEqual(connected, [endpoint], "start() must issue the initial connect")
        await repo.stop()
    }

    func test_foregroundSignal_triggersReconnect() async throws {
        let transport = FakeInboxTransport()
        let foreground = makeSignals()
        let repo = TransportLifecycleRepository(
            transport: transport,
            foregroundSignals: foreground.stream,
            connectivitySignals: makeSignals().stream
        )
        await repo.start(endpoints: [])

        foreground.fire()
        try await waitUntil { await transport.reconnectCallCount >= 1 }

        foreground.fire()
        try await waitUntil { await transport.reconnectCallCount >= 2 }
        await repo.stop()
    }

    func test_connectivitySignal_triggersReconnect() async throws {
        let transport = FakeInboxTransport()
        let connectivity = makeSignals()
        let repo = TransportLifecycleRepository(
            transport: transport,
            foregroundSignals: makeSignals().stream,
            connectivitySignals: connectivity.stream
        )
        await repo.start(endpoints: [])

        connectivity.fire()
        try await waitUntil { await transport.reconnectCallCount >= 1 }
        await repo.stop()
    }

    func test_connectionSnapshots_replayCurrentAndMirrorTransport() async throws {
        // FakeInboxTransport uses the protocol's default state stream
        // (permanently connected) — the repository must replay `true`
        // on subscribe.
        let transport = FakeInboxTransport()
        let repo = TransportLifecycleRepository(
            transport: transport,
            foregroundSignals: makeSignals().stream,
            connectivitySignals: makeSignals().stream
        )
        await repo.start(endpoints: [])

        var iterator = repo.connectionSnapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, true)
        await repo.stop()
    }

    func test_stop_endsTriggerForwarding() async throws {
        let transport = FakeInboxTransport()
        let foreground = makeSignals()
        let repo = TransportLifecycleRepository(
            transport: transport,
            foregroundSignals: foreground.stream,
            connectivitySignals: makeSignals().stream
        )
        await repo.start(endpoints: [])
        await repo.stop()

        foreground.fire()
        try await Task.sleep(for: .milliseconds(300))
        let count = await transport.reconnectCallCount
        XCTAssertEqual(count, 0, "a stopped repository must not forward triggers")
    }

    /// End-to-end state signal against the loopback relay: connected
    /// flips true when a frame confirms the socket live, and false when
    /// the relay dies while backoff retries run.
    func test_connectionState_reflectsRelayLiveness() async throws {
        let relay = try LocalWebSocketRelay()
        let transport = NostrInboxTransport(
            signerProvider: OnymNostrSignerProvider(),
            highWaterMarks: UserDefaultsInboxTransportTestStore()
        )
        let url = URL(string: "ws://127.0.0.1:\(try await relay.port())")!

        let repo = TransportLifecycleRepository(
            transport: transport,
            foregroundSignals: makeSignals().stream,
            connectivitySignals: makeSignals().stream
        )
        await repo.start(endpoints: [TransportEndpoint(url: url)])

        let states = StateBox()
        let snapshots = repo.connectionSnapshots
        let pump = Task { for await state in snapshots { await states.append(state) } }
        defer { pump.cancel() }

        // A subscription draws an EOSE — the confirming frame.
        let stream = transport.subscribe(inbox: TransportInboxID(rawValue: "feed0001"))
        let subPump = Task { for await _ in stream {} }
        defer { subPump.cancel() }

        try await waitUntil { await states.all().contains(true) }

        // Kill the relay entirely: the receive error tears the socket
        // down and reconnect attempts fail — state must flip false.
        relay.stop()
        try await waitUntil { await states.all().last == false }
        await repo.stop()
        await transport.disconnect()
    }
}

private actor StateBox {
    private var values: [Bool] = []
    func append(_ value: Bool) { values.append(value) }
    func all() -> [Bool] { values }
}

/// Isolated HWM store so the state test never touches shared defaults.
private final class UserDefaultsInboxTransportTestStore: InboxHighWaterMarkStoring, @unchecked Sendable {
    private let inner = UserDefaultsInboxHighWaterMarkStore(
        defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    )
    func highWaterMark(inbox: String) -> Int64? { inner.highWaterMark(inbox: inbox) }
    func raise(inbox: String, to createdAt: Int64) { inner.raise(inbox: inbox, to: createdAt) }
}
