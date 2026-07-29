import XCTest
@testable import OnymIOS

/// Regression coverage for the "messages only arrive after a hard
/// relaunch" bug: once the launch-time WebSocket died, nothing rebuilt
/// it, so a live subscription silently stopped delivering. These tests
/// drive a real `NostrRelayConnection` against a loopback WebSocket relay
/// and assert that a subscription keeps delivering across a connection
/// loss — both via the passive error-path reconnect and via an explicit
/// `reconnect()` (the app's foreground / connectivity trigger).
final class NostrRelayConnectionReconnectTests: XCTestCase {
    /// A subscription established before a drop must resume delivering
    /// after `reconnect()` rebuilds the socket and replays the REQ.
    func testSubscriptionResumesAfterForcedReconnect() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let url = URL(string: "ws://127.0.0.1:\(try relay.port())")!

        let conn = NostrRelayConnection(url: url)
        await conn.connect()

        let collector = EventCollector()
        let stream = await conn.subscribe(subscriptionID: "sub1", filter: ["kinds": [44114]])
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        try relay.waitForConnections(1)

        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "before-drop", tag: ("t", "topic")
        ))
        try await collector.waitForCount(1)

        // Kill the socket and force the app-level reconnect.
        relay.dropCurrentConnection()
        await conn.reconnect()
        try relay.waitForConnections(2)

        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "after-reconnect", tag: ("t", "topic")
        ))
        try await collector.waitForCount(2)

        let contents = await collector.contents()
        XCTAssertEqual(contents, ["before-drop", "after-reconnect"])
    }

    /// Same guarantee via the passive path: a server-initiated drop makes
    /// `receive()` throw, and the receive loop's own backoff reconnect
    /// must restore delivery without any external nudge.
    func testSubscriptionResumesAfterServerDrop() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let url = URL(string: "ws://127.0.0.1:\(try relay.port())")!

        let conn = NostrRelayConnection(url: url)
        await conn.connect()

        let collector = EventCollector()
        let stream = await conn.subscribe(subscriptionID: "sub1", filter: ["kinds": [44114]])
        let pump = Task { for await event in stream { await collector.append(event) } }
        defer { pump.cancel() }

        try relay.waitForConnections(1)
        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "first", tag: ("t", "topic")
        ))
        try await collector.waitForCount(1)

        // Server drops the connection; the error-path reconnect (base
        // backoff ~1s) should re-establish and replay the REQ on its own.
        relay.dropCurrentConnection()
        try relay.waitForConnections(2, timeout: 6)

        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "sub1", kind: 44114, content: "second", tag: ("t", "topic")
        ))
        try await collector.waitForCount(2, timeout: 6)

        let contents = await collector.contents()
        XCTAssertEqual(contents, ["first", "second"])
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
