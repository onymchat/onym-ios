import XCTest
@testable import OnymIOS

/// Regression coverage for the "messages only arrive after a hard
/// relaunch" bug: once the launch-time WebSocket died, nothing rebuilt
/// it, so a live subscription silently stopped delivering. These tests
/// drive a real `NostrRelayConnection` against a loopback WebSocket relay
/// and assert delivery survives a connection loss — via an explicit
/// `forceReconnect()`, via the passive error-path reconnect, and via the
/// liveness monitor healing a half-open socket that never errors.
final class NostrRelayConnectionReconnectTests: XCTestCase {
    /// A subscription established before a drop must resume delivering
    /// after `forceReconnect()`, and the relay must actually see the REQ
    /// replayed on the new socket (not merely a re-opened connection).
    func testSubscriptionResumesAndReplaysREQAfterForcedReconnect() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let url = URL(string: "ws://127.0.0.1:\(try await relay.port())")!

        let conn = NostrRelayConnection(url: url)
        await conn.connect()

        let collector = EventCollector()
        let stream = await conn.subscribe(subscriptionID: "sub1", filter: ["kinds": [44114]])
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)

        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "before-drop", tag: ("t", "topic")
        ))
        try await collector.waitForCount(1)

        // Kill the socket and force the app-level reconnect.
        let reqsBefore = relay.reqCount()
        relay.dropCurrentConnection()
        await conn.forceReconnect()
        try await relay.waitForConnections(2)
        // The REQ was actually replayed on the rebuilt socket.
        try await relay.waitForREQs(reqsBefore + 1)

        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "after-reconnect", tag: ("t", "topic")
        ))
        try await collector.waitForCount(2)

        let contents = await collector.contents()
        XCTAssertEqual(contents, ["before-drop", "after-reconnect"])
    }

    /// The reported bug: a message that arrived while the client was
    /// "away" (backgrounded) must be backfilled when it re-subscribes —
    /// the relay only replays stored events in response to a fresh REQ, so
    /// the reconnect MUST re-issue the subscription. Models the exact
    /// symptom: no live push happens; delivery comes purely from the
    /// reconnect's REQ replay.
    func testForcedReconnectBackfillsMessageStoredWhileAway() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let url = URL(string: "ws://127.0.0.1:\(try await relay.port())")!

        let conn = NostrRelayConnection(url: url)
        await conn.connect()

        let collector = EventCollector()
        let stream = await conn.subscribe(subscriptionID: "sub1", filter: ["kinds": [34113]])
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }
        try await relay.waitForConnections(1)

        // A message lands on the relay while the client is "backgrounded":
        // stored, never pushed live to this socket.
        relay.store(subID: "sub1", eventJSON: LocalWebSocketRelay.eventObjectJSON(
            kind: 34113, content: "missed-while-bg", tag: ("d", "sep-inbox:abc")
        ))

        // Foreground → unconditional rebuild + re-subscribe. The relay
        // replays the stored event on the fresh REQ.
        await conn.forceReconnect()
        try await relay.waitForConnections(2)
        try await collector.waitForCount(1)

        let contents = await collector.contents()
        XCTAssertEqual(contents, ["missed-while-bg"],
                       "reconnect must re-subscribe so the relay backfills the message missed while away")
    }

    /// Passive path: a server-initiated drop makes `receive()` throw, and
    /// the receive loop's own backoff reconnect restores delivery with no
    /// external nudge.
    func testSubscriptionResumesAfterServerDrop() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let url = URL(string: "ws://127.0.0.1:\(try await relay.port())")!

        let conn = NostrRelayConnection(url: url, baseReconnectDelay: 0.1, maxReconnectDelay: 0.5)
        await conn.connect()

        let collector = EventCollector()
        let stream = await conn.subscribe(subscriptionID: "sub1", filter: ["kinds": [44114]])
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        try await relay.waitForConnections(1)
        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "first", tag: ("t", "topic")
        ))
        try await collector.waitForCount(1)

        relay.dropCurrentConnection()
        try await relay.waitForConnections(2, timeout: 6)

        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "second", tag: ("t", "topic")
        ))
        try await collector.waitForCount(2, timeout: 6)

        let contents = await collector.contents()
        XCTAssertEqual(contents, ["first", "second"])
    }

    /// The half-open case the error path can't catch: the socket stays
    /// "open" but delivers nothing (the loopback relay never answers the
    /// liveness probe). With a short liveness window the monitor must
    /// detect the silence and rebuild the socket on its own.
    func testLivenessMonitorHealsHalfOpenSocket() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let url = URL(string: "ws://127.0.0.1:\(try await relay.port())")!

        let conn = NostrRelayConnection(
            url: url,
            pingInterval: 0.1,
            livenessTimeout: 0.3,
            baseReconnectDelay: 0.05,
            maxReconnectDelay: 0.2
        )
        await conn.connect()
        _ = await conn.subscribe(subscriptionID: "sub1", filter: ["kinds": [44114]])

        try await relay.waitForConnections(1)
        // No pushes, no drop — a healthy-looking but silent socket. The
        // liveness monitor should force a rebuild once the window lapses.
        let reconnected = try await relay.waitForConnections(2, timeout: 3)
        XCTAssertGreaterThanOrEqual(reconnected, 2)

        await conn.disconnect()
    }
}

/// Actor sink for events pumped off a subscription stream, with a poll
/// helper so tests can await a target count without racing the stream.
private actor EventCollector {
    private var events: [NostrEvent] = []

    func append(_ event: NostrEvent) { events.append(event) }
    func contents() -> [String] { events.map(\.content) }
    private func count() -> Int { events.count }

    func waitForCount(_ target: Int, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if count() >= target { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CollectorError.timeout
    }

    enum CollectorError: Error { case timeout }
}
