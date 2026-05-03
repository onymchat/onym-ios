import CryptoKit
import XCTest
@testable import OnymIOS

/// Behavioral tests for `InboxFanoutInteractor`. Uses a real
/// `IdentityRepository` (isolated keychain) so the inbox-tag derivation
/// matches what production sees, plus a fake `InboxTransport` that
/// records subscribe/unsubscribe + can inject inbound messages.
@MainActor
final class InboxFanoutInteractorTests: XCTestCase {
    private var keychain: IdentityKeychainStore!
    private var identity: IdentityRepository!
    private var invitationsStore: FanoutInvitationStore!
    private var invitations: IncomingInvitationsRepository!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "fanout-\(UUID().uuidString)")
        identity = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
        invitationsStore = FanoutInvitationStore()
        invitations = IncomingInvitationsRepository(store: invitationsStore)
    }

    override func tearDown() async throws {
        try? keychain?.wipeAll()
        keychain = nil
        identity = nil
        invitationsStore = nil
        invitations = nil
        try await super.tearDown()
    }

    // MARK: - Initial subscription set

    func test_run_subscribesToEveryExistingIdentity() async throws {
        // Seed two identities BEFORE running.
        _ = try await identity.bootstrap()                      // Identity 1
        _ = try await identity.add(name: "Work")                // Identity 2
        let summaries = await identity.currentIdentities()
        XCTAssertEqual(summaries.count, 2)

        let transport = RecordingInboxTransport()
        let fanout = InboxFanoutInteractor(
            inboxTransport: transport,
            identityRepository: identity,
            repository: invitations,
            debounceMilliseconds: 1   // tight for tests
        )
        let runTask = Task { await fanout.run() }
        defer { runTask.cancel() }

        // Wait until both subscribe calls land.
        try await waitFor { await transport.subscribed.count >= 2 }
        let live = await transport.subscribed
        XCTAssertEqual(live.count, 2)
        // Tags match the identities' inbox tags.
        let expectedTags = Set(summaries.map(\.inboxPublicKey).map(Self.expectedTag))
        XCTAssertEqual(Set(live.map(\.rawValue)), expectedTags)
    }

    // MARK: - Add / remove during run

    func test_addingIdentity_triggersNewSubscription() async throws {
        _ = try await identity.bootstrap()  // Identity 1

        let transport = RecordingInboxTransport()
        let fanout = InboxFanoutInteractor(
            inboxTransport: transport,
            identityRepository: identity,
            repository: invitations,
            debounceMilliseconds: 1
        )
        let runTask = Task { await fanout.run() }
        defer { runTask.cancel() }

        try await waitFor { await transport.subscribed.count >= 1 }
        let count1 = await transport.subscribed.count
        XCTAssertEqual(count1, 1)

        _ = try await identity.add(name: "Work")
        try await waitFor { await transport.subscribed.count >= 2 }
        let count2 = await transport.subscribed.count
        XCTAssertEqual(count2, 2)
    }

    func test_removingIdentity_triggersUnsubscribe() async throws {
        _ = try await identity.bootstrap()
        let workID = try await identity.add(name: "Work")
        let summaries = await identity.currentIdentities()
        let workSummary = try XCTUnwrap(summaries.first(where: { $0.id == workID }))

        let transport = RecordingInboxTransport()
        let fanout = InboxFanoutInteractor(
            inboxTransport: transport,
            identityRepository: identity,
            repository: invitations,
            debounceMilliseconds: 1
        )
        let runTask = Task { await fanout.run() }
        defer { runTask.cancel() }

        try await waitFor { await transport.subscribed.count >= 2 }
        try await identity.remove(workID)
        try await waitFor { await transport.unsubscribed.count >= 1 }

        let dropped = await transport.unsubscribed
        XCTAssertEqual(dropped.first?.rawValue, Self.expectedTag(workSummary.inboxPublicKey))
        // The remaining identity stays subscribed.
        let totalSubscribes = await transport.subscribed.count
        XCTAssertEqual(totalSubscribes, 2,
                       "subscribe is cumulative — only unsubscribe should fire on remove")
    }

    // MARK: - Inbound delivery

    func test_inboundMessage_landsInRepository() async throws {
        let activeIdentity = try await identity.bootstrap()
        let summaries = await identity.currentIdentities()
        let summary = try XCTUnwrap(
            summaries.first(where: { $0.blsPublicKey == activeIdentity.blsPublicKey })
        )
        let tag = TransportInboxID(rawValue: Self.expectedTag(summary.inboxPublicKey))

        let transport = RecordingInboxTransport()
        let fanout = InboxFanoutInteractor(
            inboxTransport: transport,
            identityRepository: identity,
            repository: invitations,
            debounceMilliseconds: 1
        )
        let runTask = Task { await fanout.run() }
        defer { runTask.cancel() }

        try await waitFor { await transport.subscribed.contains(tag) }

        await transport.inject(
            InboundInbox(
                inbox: tag,
                payload: Data("envelope-bytes".utf8),
                receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                messageID: "msg-1"
            )
        )

        let store = invitationsStore!
        try await waitFor { await store.count >= 1 }
        let stored = await store.snapshot()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, "msg-1")
    }

    // MARK: - Helpers

    /// Mirror of `IdentityRepository.inboxTag(from:)` (private). Kept
    /// as test code so a drift in the production formula breaks here
    /// loudly.
    private static func expectedTag(_ inboxPublicKey: Data) -> String {
        var hasher = _TagHasher()
        hasher.update(Data("sep-inbox-v1".utf8))
        hasher.update(inboxPublicKey)
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Simple poll-until-true helper. The fanout uses async tasks +
    /// debouncing, so deterministic waits aren't possible without
    /// gluing into the interactor's internals.
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

/// Tiny SHA-256 wrapper — keeps the inbox-tag derivation in the test
/// file readable without leaking CryptoKit's API into call sites.
private struct _TagHasher {
    private var data = Data()
    mutating func update(_ chunk: Data) { data.append(chunk) }
    func finalize() -> [UInt8] { Array(SHA256.hash(data: data)) }
}

private actor RecordingInboxTransport: InboxTransport {
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
            Task { await self.registerSubscription(inbox: inbox, continuation: continuation) }
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

    private func registerSubscription(
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

private actor FanoutInvitationStore: InvitationStore {
    private var rows: [String: IncomingInvitationRecord] = [:]

    var count: Int { rows.count }
    func snapshot() -> [IncomingInvitationRecord] { Array(rows.values) }

    func list() -> [IncomingInvitationRecord] {
        rows.values.sorted { $0.receivedAt > $1.receivedAt }
    }

    @discardableResult
    func save(_ record: IncomingInvitationRecord) -> Bool {
        guard rows[record.id] == nil else { return false }
        rows[record.id] = record
        return true
    }

    func updateStatus(id: String, status: IncomingInvitationStatus) {
        guard var existing = rows[id] else { return }
        existing = IncomingInvitationRecord(
            id: existing.id,
            payload: existing.payload,
            receivedAt: existing.receivedAt,
            status: status
        )
        rows[id] = existing
    }

    func delete(id: String) {
        rows.removeValue(forKey: id)
    }
}
