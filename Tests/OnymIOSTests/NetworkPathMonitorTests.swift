import XCTest
@testable import OnymIOS

/// Unit tests for `ConnectivityRegainDetector` — the emission policy
/// behind `NetworkPathMonitor`. The two field-proven failure modes it
/// must prevent: a reconnect storm from satisfied→satisfied path churn
/// (design doc F2), and a swallowed regain after a launch-offline start.
final class NetworkPathMonitorTests: XCTestCase {
    func test_baselineCallbackNeverEmits() {
        let detector = ConnectivityRegainDetector(cooldown: 0)
        XCTAssertFalse(detector.shouldEmit(satisfied: true),
                       "the first (baseline) callback must not emit")
    }

    func test_offlineLaunchThenRegain_emits() {
        // Launch offline → connectivity arrives. The one-shot-latch
        // design swallowed this; the edge detector must fire.
        let detector = ConnectivityRegainDetector(cooldown: 0)
        XCTAssertFalse(detector.shouldEmit(satisfied: false))  // baseline, offline
        XCTAssertTrue(detector.shouldEmit(satisfied: true), "offline→online must emit")
    }

    func test_satisfiedChurn_doesNotEmit() {
        let detector = ConnectivityRegainDetector(cooldown: 0)
        _ = detector.shouldEmit(satisfied: true)  // baseline, online
        XCTAssertFalse(detector.shouldEmit(satisfied: true),
                       "interface churn while satisfied must not emit (reconnect storm)")
        XCTAssertFalse(detector.shouldEmit(satisfied: true))
    }

    func test_dropAndRegain_emitsOnce() {
        let detector = ConnectivityRegainDetector(cooldown: 0)
        _ = detector.shouldEmit(satisfied: true)   // baseline
        XCTAssertFalse(detector.shouldEmit(satisfied: false))
        XCTAssertTrue(detector.shouldEmit(satisfied: true))
        XCTAssertFalse(detector.shouldEmit(satisfied: true), "no re-emit while staying satisfied")
    }

    func test_flapping_isCoalescedWithinCooldown() {
        var now = Date(timeIntervalSince1970: 1_000)
        let detector = ConnectivityRegainDetector(cooldown: 3, now: { now })
        _ = detector.shouldEmit(satisfied: true)   // baseline online

        now = now.addingTimeInterval(0.1)
        _ = detector.shouldEmit(satisfied: false)
        XCTAssertTrue(detector.shouldEmit(satisfied: true), "first regain emits")

        // A rapid flap inside the cooldown is swallowed.
        now = now.addingTimeInterval(0.5)
        _ = detector.shouldEmit(satisfied: false)
        XCTAssertFalse(detector.shouldEmit(satisfied: true),
                       "a regain within the cooldown must be coalesced")

        // After the cooldown lapses, a regain emits again.
        now = now.addingTimeInterval(5)
        _ = detector.shouldEmit(satisfied: false)
        XCTAssertTrue(detector.shouldEmit(satisfied: true))
    }
}

/// Transport-level: `InboxTransport.reconnect()` must rebuild the socket,
/// replay the REQ, and thereby backfill an event stored while away — the
/// full foreground-refresh path minus the app trigger.
final class NostrInboxTransportReconnectTests: XCTestCase {
    func test_reconnect_rebuildsAndBackfillsStoredEvent() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let transport = NostrInboxTransport(
            signerProvider: OnymNostrSignerProvider(),
            highWaterMarks: UserDefaultsInboxHighWaterMarkStore(
                defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
            )
        )
        let url = URL(string: "ws://127.0.0.1:\(try await relay.port())")!
        await transport.connect(to: [TransportEndpoint(url: url)])

        let inbox = TransportInboxID(rawValue: "cafe0001")
        let received = ReceivedMessages()
        let stream = transport.subscribe(inbox: inbox)
        let pump = Task { for await msg in stream { await received.append(msg.messageID) } }
        defer { pump.cancel() }
        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)

        // Arrives while "backgrounded": stored on the relay, never
        // pushed live to this socket. Keyed to the subID the transport
        // actually REQ'd (generation-suffixed) — a reconnect replays the
        // same subscription id.
        relay.store(subID: relay.lastRecordedSubID()!, eventJSON: LocalWebSocketRelay.eventObjectJSON(
            kind: 34113,
            content: Data("missed".utf8).base64EncodedString(),
            tag: ("d", "sep-inbox:cafe0001")
        ))

        await transport.reconnect()
        try await relay.waitForConnections(2)
        try await relay.waitForREQs(2)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let count = await received.count()
            if count >= 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let ids = await received.all()
        XCTAssertEqual(ids.count, 1,
                       "reconnect() must re-REQ so the relay backfills the missed event")
        await transport.disconnect()
    }
}

private actor ReceivedMessages {
    private var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
    func all() -> [String] { ids }
    func count() -> Int { ids.count }
}
