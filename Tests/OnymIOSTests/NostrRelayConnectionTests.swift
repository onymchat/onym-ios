import XCTest
@testable import OnymIOS

/// Behavioral tests for `NostrRelayConnection`'s lifecycle state machine,
/// driven against a loopback WebSocket relay (`LocalWebSocketRelay`).
/// Regression coverage for the field failure modes in the reconnect
/// design doc: dead-until-relaunch (F1), missed-backfill-on-foreground
/// (F3), silently-CLOSED subscriptions (F8), and half-open sockets the
/// error path can't see.
final class NostrRelayConnectionTests: XCTestCase {
    /// One subscription = one REQ frame carrying all of its filters —
    /// never one REQ per filter (relay `maxSubsPerConnection` caps).
    func testSubscribeSendsSingleREQWithAllFilters() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(url: try await relay.wsURL())
        await conn.connect()

        let filters: [[String: Any]] = [
            ["kinds": [34113], "#d": ["sep-inbox:abc"]],
            ["kinds": [34113], "#t": ["abc"]],
            ["kinds": [24113], "#t": ["abc"]],
        ]
        _ = await conn.subscribe(subscriptionID: "inbox-abc", filters: filters)

        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)
        // Give a straggler REQ a beat to show up if the code regressed
        // to one-REQ-per-filter.
        try await Task.sleep(for: .milliseconds(150))

        let recorded = relay.reqs(subID: "inbox-abc")
        XCTAssertEqual(recorded.count, 1, "exactly one REQ for the subscription")
        XCTAssertEqual(recorded[0].count, 3, "the single REQ carries all three filters")
        await conn.disconnect()
    }

    /// A subscription established before a server-side drop must resume
    /// delivering after the passive error-path reconnect — no external
    /// trigger.
    func testSubscriptionResumesAfterServerDrop() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(
            url: try await relay.wsURL(),
            baseReconnectDelay: 0.1,
            maxReconnectDelay: 0.5
        )
        await conn.connect()

        let collector = EventCollector()
        let stream = await conn.subscribe(subscriptionID: "sub1", filters: [["kinds": [34113]]])
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        try await relay.waitForConnections(1)
        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 34113, content: "first", tag: ("t", "x")
        ))
        try await collector.waitForCount(1)

        relay.dropCurrentConnection()
        try await relay.waitForConnections(2, timeout: 6)

        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 34113, content: "second", tag: ("t", "x")
        ))
        try await collector.waitForCount(2, timeout: 6)

        let contents = await collector.contents()
        XCTAssertEqual(contents, ["first", "second"])
        await conn.disconnect()
    }

    /// The canonical background→foreground bug (design doc F3): a message
    /// stored on the relay while the client was away arrives only via the
    /// fresh REQ's backfill. `forceReconnect()` must rebuild AND re-REQ —
    /// no live push happens in this test at all.
    func testForceReconnectBackfillsEventStoredWhileAway() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(url: try await relay.wsURL())
        await conn.connect()

        let collector = EventCollector()
        let stream = await conn.subscribe(subscriptionID: "sub1", filters: [["kinds": [34113]]])
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }
        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)

        // Arrives at the relay while the client is "suspended": stored,
        // never pushed live to this socket.
        relay.store(subID: "sub1", eventJSON: LocalWebSocketRelay.eventObjectJSON(
            kind: 34113, content: "missed-while-bg", tag: ("d", "sep-inbox:abc")
        ))

        let reqsBefore = relay.reqCount()
        await conn.forceReconnect()
        try await relay.waitForConnections(2)
        try await relay.waitForREQs(reqsBefore + 1)
        try await collector.waitForCount(1)

        let contents = await collector.contents()
        XCTAssertEqual(contents, ["missed-while-bg"],
                       "the rebuilt connection's REQ must backfill the missed event")
        await conn.disconnect()
    }

    /// Half-open socket (design doc F1): the peer goes silent without
    /// closing, `receive()` never throws, so only the liveness monitor
    /// can notice. With test-scale timings it must rebuild on its own.
    func testLivenessMonitorHealsSilentSocket() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        relay.autoRespondEOSE = false  // silent peer: no EOSE, no replies

        let conn = NostrRelayConnection(
            url: try await relay.wsURL(),
            pingInterval: 0.1,
            livenessTimeout: 0.3,
            baseReconnectDelay: 0.05,
            maxReconnectDelay: 0.2
        )
        await conn.connect()
        _ = await conn.subscribe(subscriptionID: "sub1", filters: [["kinds": [34113]]])

        try await relay.waitForConnections(1)
        // No traffic at all — staleness must fire and rebuild.
        let reconnected = try await relay.waitForConnections(2, timeout: 3)
        XCTAssertGreaterThanOrEqual(reconnected, 2)
        await conn.disconnect()
    }

    /// A healthy relay that answers the liveness probe (EOSE) keeps the
    /// connection alive — no spurious rebuilds from the staleness check.
    func testProbeAnsweredKeepsConnectionAlive() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }

        let conn = NostrRelayConnection(
            url: try await relay.wsURL(),
            pingInterval: 0.1,
            livenessTimeout: 0.3,
            baseReconnectDelay: 0.05,
            maxReconnectDelay: 0.2
        )
        await conn.connect()
        _ = await conn.subscribe(subscriptionID: "sub1", filters: [["kinds": [34113]]])

        try await relay.waitForConnections(1)
        // Several liveness windows pass; probe EOSEs keep it alive.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(relay.connectionCount(), 1,
                       "a probe-answering relay must not trigger rebuilds")
        await conn.disconnect()
    }

    /// First `CLOSED` for a subscription re-issues its REQ once (design
    /// doc F8: a silently rejected subscription must be retried, not
    /// ignored).
    func testCLOSEDTriggersOneResubscribe() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(url: try await relay.wsURL())
        await conn.connect()
        let stream = await conn.subscribe(subscriptionID: "sub1", filters: [["kinds": [34113]]])
        let pump = Task { for await _ in stream {} }  // hold the subscription live
        defer { pump.cancel() }

        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)

        relay.sendCLOSED(subID: "sub1")
        try await relay.waitForREQs(2)

        XCTAssertEqual(relay.reqs(subID: "sub1").count, 2, "CLOSED must re-REQ the subscription")
        XCTAssertEqual(relay.connectionCount(), 1, "a single CLOSED must not rebuild the connection")
        await conn.disconnect()
    }

    /// A second `CLOSED` for the same subscription in the same connection
    /// generation means the rejection is persistent — escalate to a full
    /// rebuild (visible recovery) instead of retrying forever or going
    /// silently deaf.
    func testRepeatedCLOSEDRebuildsConnection() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(
            url: try await relay.wsURL(),
            baseReconnectDelay: 0.05,
            maxReconnectDelay: 0.2
        )
        await conn.connect()
        let stream = await conn.subscribe(subscriptionID: "sub1", filters: [["kinds": [34113]]])
        let pump = Task { for await _ in stream {} }  // hold the subscription live
        defer { pump.cancel() }

        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)

        relay.sendCLOSED(subID: "sub1")
        try await relay.waitForREQs(2)
        relay.sendCLOSED(subID: "sub1")

        try await relay.waitForConnections(2, timeout: 4)
        // The rebuilt connection replays the subscription.
        try await relay.waitForREQs(3, timeout: 4)
        await conn.disconnect()
    }

    /// `CLOSED` for an unknown subscription (e.g. one we already
    /// unsubscribed) is ignored — no retry, no rebuild.
    func testCLOSEDForUnknownSubIsIgnored() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(url: try await relay.wsURL())
        await conn.connect()
        _ = await conn.subscribe(subscriptionID: "sub1", filters: [["kinds": [34113]]])

        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)

        relay.sendCLOSED(subID: "no-such-sub")
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(relay.reqCount(), 1)
        XCTAssertEqual(relay.connectionCount(), 1)
        await conn.disconnect()
    }
}

// MARK: - Helpers

private extension LocalWebSocketRelay {
    func wsURL() async throws -> URL {
        URL(string: "ws://127.0.0.1:\(try await port())")!
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
