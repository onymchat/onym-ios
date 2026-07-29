import XCTest
@testable import OnymIOS

/// PR-3 of the reconnect design: reconnect replays must be cheap so
/// "always re-REQ" is safe. Covers the persisted high-water-mark store,
/// the `since` bound applied at REQ-send time (initial + replay), the
/// transport raising the mark as events arrive, and the durable
/// seen-event-id dedup in the fan-out.
final class BoundedReplayTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    // MARK: - InboxHighWaterMarkStore

    func test_hwmStore_unsetReturnsNil_raiseRoundTrips() {
        let store = UserDefaultsInboxHighWaterMarkStore(defaults: isolatedDefaults())
        XCTAssertNil(store.highWaterMark(inbox: "abc"))
        store.raise(inbox: "abc", to: 1_700_000_000)
        XCTAssertEqual(store.highWaterMark(inbox: "abc"), 1_700_000_000)
    }

    func test_hwmStore_neverLowers() {
        let store = UserDefaultsInboxHighWaterMarkStore(defaults: isolatedDefaults())
        store.raise(inbox: "abc", to: 2_000)
        store.raise(inbox: "abc", to: 1_000)  // stale replayed event
        XCTAssertEqual(store.highWaterMark(inbox: "abc"), 2_000)
    }

    func test_hwmStore_persistsAcrossInstances() {
        let defaults = isolatedDefaults()
        UserDefaultsInboxHighWaterMarkStore(defaults: defaults).raise(inbox: "abc", to: 42)
        let reloaded = UserDefaultsInboxHighWaterMarkStore(defaults: defaults)
        XCTAssertEqual(reloaded.highWaterMark(inbox: "abc"), 42)
    }

    func test_hwmStore_isPerInbox() {
        let store = UserDefaultsInboxHighWaterMarkStore(defaults: isolatedDefaults())
        store.raise(inbox: "a", to: 10)
        XCTAssertNil(store.highWaterMark(inbox: "b"))
    }

    // MARK: - SeenEventIDStore

    func test_seenStore_markAndContains() async {
        let store = SeenEventIDStore(defaults: isolatedDefaults())
        let seenBefore = await store.contains("e1")
        XCTAssertFalse(seenBefore)
        await store.markSeen("e1")
        let seenAfter = await store.contains("e1")
        XCTAssertTrue(seenAfter)
    }

    func test_seenStore_evictsOldestBeyondCapacity() async {
        let store = SeenEventIDStore(defaults: isolatedDefaults(), capacity: 3)
        for id in ["a", "b", "c", "d"] { await store.markSeen(id) }
        let aSeen = await store.contains("a")
        let dSeen = await store.contains("d")
        XCTAssertFalse(aSeen, "oldest id must be evicted at capacity")
        XCTAssertTrue(dSeen)
    }

    func test_seenStore_persistsAcrossInstances() async throws {
        let defaults = isolatedDefaults()
        let store = SeenEventIDStore(defaults: defaults, capacity: 10)
        await store.markSeen("e1")
        // Persistence is debounced ~1s; wait it out.
        try await Task.sleep(for: .milliseconds(1400))
        let reloaded = SeenEventIDStore(defaults: defaults, capacity: 10)
        let seen = await reloaded.contains("e1")
        XCTAssertTrue(seen, "seen ids must survive a relaunch")
    }

    // MARK: - Connection applies `since` at REQ-send time

    func test_connection_sinceProvider_boundsInitialREQ() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(url: URL(string: "ws://127.0.0.1:\(try await relay.port())")!)
        await conn.connect()

        let stream = await conn.subscribe(
            subscriptionID: "s1",
            filters: [["kinds": [34113]], ["kinds": [24113]]],
            sinceProvider: { 1_000 }
        )
        let pump = Task { for await _ in stream {} }
        defer { pump.cancel() }

        try await relay.waitForREQs(1)
        let filters = relay.reqs(subID: "s1")[0]
        XCTAssertEqual(filters.count, 2)
        for filter in filters {
            XCTAssertEqual(filter["since"] as? Int, 1_000, "every filter must carry the since bound")
        }
        await conn.disconnect()
    }

    func test_connection_sinceProvider_neverLowersExplicitSince() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(url: URL(string: "ws://127.0.0.1:\(try await relay.port())")!)
        await conn.connect()

        let stream = await conn.subscribe(
            subscriptionID: "s1",
            filters: [["kinds": [44114], "since": Int64(5_000)]],
            sinceProvider: { 1_000 }
        )
        let pump = Task { for await _ in stream {} }
        defer { pump.cancel() }

        try await relay.waitForREQs(1)
        let filter = relay.reqs(subID: "s1")[0][0]
        XCTAssertEqual(filter["since"] as? Int, 5_000,
                       "a stricter caller-supplied since must win")
        await conn.disconnect()
    }

    func test_connection_replayREQ_usesCurrentProviderValue() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let conn = NostrRelayConnection(url: URL(string: "ws://127.0.0.1:\(try await relay.port())")!)
        await conn.connect()

        // The provider reads mutable state — the replay must see the
        // *current* value, not one frozen at subscribe time.
        let hwm = UserDefaultsInboxHighWaterMarkStore(defaults: isolatedDefaults())
        let stream = await conn.subscribe(
            subscriptionID: "s1",
            filters: [["kinds": [34113]]],
            sinceProvider: { hwm.highWaterMark(inbox: "x") }
        )
        let pump = Task { for await _ in stream {} }
        defer { pump.cancel() }

        try await relay.waitForConnections(1)
        try await relay.waitForREQs(1)
        XCTAssertNil(relay.reqs(subID: "s1")[0][0]["since"],
                     "no mark yet: the cold-start REQ must be unbounded")

        hwm.raise(inbox: "x", to: 9_000)
        await conn.forceReconnect()
        try await relay.waitForREQs(2)
        XCTAssertEqual(relay.reqs(subID: "s1")[1][0]["since"] as? Int, 9_000,
                       "the reconnect replay must be bounded by the current mark")
        await conn.disconnect()
    }

    // MARK: - Transport raises the mark as events arrive

    func test_inboxTransport_raisesHWMOnEvent() async throws {
        let relay = try LocalWebSocketRelay()
        defer { relay.stop() }
        let defaults = isolatedDefaults()
        let hwm = UserDefaultsInboxHighWaterMarkStore(defaults: defaults)
        let transport = NostrInboxTransport(
            signerProvider: OnymNostrSignerProvider(),
            highWaterMarks: hwm
        )
        let url = URL(string: "ws://127.0.0.1:\(try await relay.port())")!
        await transport.connect(to: [TransportEndpoint(url: url)])

        let inbox = TransportInboxID(rawValue: "abcd1234")
        let stream = transport.subscribe(inbox: inbox)
        let received = ReceivedBox()
        let pump = Task { for await msg in stream { await received.append(msg.messageID) } }
        defer { pump.cancel() }

        try await relay.waitForREQs(1)
        // The harness event's created_at is 1_700_000_000; content must
        // be base64 for the transport to yield it.
        relay.push(LocalWebSocketRelay.eventFrame(
            subID: "inbox-abcd1234", kind: 34113,
            content: Data("hello".utf8).base64EncodedString(),
            tag: ("d", "sep-inbox:abcd1234")
        ))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if hwm.highWaterMark(inbox: "abcd1234") != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(hwm.highWaterMark(inbox: "abcd1234"), 1_700_000_000,
                       "an arriving event must raise the inbox's high-water mark")
        await transport.disconnect()
    }

    // MARK: - Fan-out dedup

    func test_fanout_dropsAlreadySeenEventBeforeDispatch() async throws {
        // Two deliveries of the same event id (second relay / replay
        // overlap) must dispatch exactly once.
        let transport = FakeInboxTransport()
        let identityRepo = IdentityRepository(
            keychain: IdentityKeychainStore(testNamespace: "fanout-dedup-\(UUID().uuidString)")
        )
        _ = try await identityRepo.bootstrap()

        let offer = try GroupInviteOfferPayload(
            introPublicKey: Data(repeating: 0x44, count: 32),
            groupID: Data(repeating: 0x42, count: 32),
            groupName: "G",
            inviterAlias: "A"
        )
        let plaintext = try JSONEncoder().encode(offer)
        let spy = SpyPendingInvitesForFanout()
        let dispatcher = IncomingMessageDispatcher(
            envelopeDecrypter: FakeInvitationEnvelopeDecrypter(mode: .fixed(plaintext)),
            identities: identityRepo,
            groupRepository: GroupRepository(store: SwiftDataGroupStore.inMemory()),
            invitationsRepository: IncomingInvitationsRepository(store: SwiftDataInvitationStore.inMemory()),
            chainState: NoopChainStateForFanout(),
            messageRepository: MessageRepository(store: SwiftDataMessageStore.inMemory()),
            pendingInvites: spy
        )

        let fanout = InboxFanoutInteractor(
            inboxTransport: transport,
            identityRepository: identityRepo,
            dispatcher: dispatcher,
            seenEventIDs: SeenEventIDStore(defaults: isolatedDefaults())
        )
        let run = Task { await fanout.run() }
        defer { run.cancel() }

        // Wait for the fanout's subscription to land, then deliver the
        // same event id twice.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let count = await transport.subscribeCallCount
            if count >= 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let inbox = await transport.subscribedInboxes.first
        let message = InboundInbox(
            inbox: inbox!, payload: Data("envelope".utf8),
            receivedAt: Date(), messageID: "same-event-id"
        )
        await transport.emit(message)
        try await Task.sleep(for: .milliseconds(300))
        await transport.emit(message)
        try await Task.sleep(for: .milliseconds(300))

        let recorded = await spy.all()
        XCTAssertEqual(recorded.count, 1, "a re-delivered event id must not re-dispatch")
        await transport.finish()
    }
}

// MARK: - Test doubles

private actor ReceivedBox {
    private var ids: [String] = []
    func append(_ id: String) { ids.append(id) }
    func all() -> [String] { ids }
}

private actor SpyPendingInvitesForFanout: PendingInvitesRecording {
    private var recorded: [PendingInvite] = []
    func record(_ invite: PendingInvite) async { recorded.append(invite) }
    func all() -> [PendingInvite] { recorded }
}

private struct NoopChainStateForFanout: ChainStateReading {
    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        throw URLError(.unsupportedURL)
    }
}
