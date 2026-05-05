import XCTest
@testable import OnymIOS

/// State-machine tests for `JoinFlow`. Mirrors `JoinViewModelTest.kt`.
/// The full crypto round-trip (joiner → seal → inviter approves →
/// sealed invitation arrives → group materializes) is covered by an
/// integration test that lands with the inviter-side approval UI in
/// a follow-up PR. JoinFlow is exercised here against a stub
/// submitRequest closure so the state machine is visible without
/// standing up the full inbox-fanout pipeline.
@MainActor
final class JoinFlowTests: XCTestCase {

    private let alice = IdentityID("11111111-1111-1111-1111-111111111111")!
    private let groupIdRaw = Data((0..<32).map { UInt8($0 + 1) })
    private let introPubRaw = Data((0..<32).map { UInt8(($0 * 3) % 251) })

    private func capability() throws -> IntroCapability {
        try IntroCapability(
            introPublicKey: introPubRaw,
            groupId: groupIdRaw,
            groupName: "Test group"
        )
    }

    func test_send_acceptedTransport_movesToAwaitingApproval() async throws {
        let env = try await harness(outcome: .sent)
        env.flow.send(displayLabel: "alice")
        try await waitFor { env.flow.state.isAwaitingApproval }
    }

    func test_send_noIdentity_movesToFailed() async throws {
        let env = try await harness(outcome: .noIdentityLoaded)
        env.flow.send(displayLabel: "alice")
        try await waitFor { env.flow.state.isFailed }
        guard case .failed(let reason) = env.flow.state else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(reason, "Sign in first.")
    }

    func test_send_transportFailed_surfacesReason() async throws {
        let env = try await harness(outcome: .transportFailed("relay timeout"))
        env.flow.send(displayLabel: "alice")
        try await waitFor { env.flow.state.isFailed }
        guard case .failed(let reason) = env.flow.state else {
            return XCTFail("expected .failed")
        }
        XCTAssertTrue(reason.contains("relay timeout"))
    }

    func test_groupAlreadyInRepository_flipsToApproved() async throws {
        let existing = makeGroup(groupID: groupIdRaw, owner: alice)
        let env = try await harness(outcome: .sent, seedGroups: [existing])
        // No send() — the watcher should pick up the existing group
        // and flip ready → approved on the first repository emission.
        try await waitFor { env.flow.state.isApproved }
        guard case .approved(let g) = env.flow.state else {
            return XCTFail("expected .approved")
        }
        XCTAssertEqual(g.id, existing.id)
    }

    func test_groupAppearsAfterSend_autoFlipsToApproved() async throws {
        let env = try await harness(outcome: .sent)
        env.flow.send(displayLabel: "alice")
        try await waitFor { env.flow.state.isAwaitingApproval }

        // Simulate the sealed-invitation pipeline materializing the
        // group post-Approval.
        await env.repo.insert(makeGroup(groupID: groupIdRaw, owner: alice))
        try await waitFor { env.flow.state.isApproved }
    }

    func test_send_debouncesRepeatedTaps_doesNotResubmit() async throws {
        let env = try await harness(outcome: .sent)
        env.flow.send(displayLabel: "alice")
        try await waitFor { env.flow.state.isAwaitingApproval }
        let beforeCount = env.callCount
        // Already in awaitingApproval — re-tap should be a no-op.
        env.flow.send(displayLabel: "alice")
        // Give the system a beat in case anything spurious fires.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(env.callCount, beforeCount, "send should not re-submit while in awaitingApproval")
    }

    // MARK: - Harness

    private struct Env {
        let flow: JoinFlow
        let repo: GroupRepository
        var callCount: Int { counter.value }
        let counter: Counter
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func bump() { lock.lock(); _value += 1; lock.unlock() }
    }

    private func harness(
        outcome: JoinRequestSender.Outcome,
        seedGroups: [ChatGroup] = []
    ) async throws -> Env {
        let store = JoinTestableInMemoryGroupStore()
        await store.preload(seedGroups)
        let repo = GroupRepository(store: store, currentIdentityID: alice)
        let counter = Counter()
        let cap = try capability()
        let flow = JoinFlow(
            capability: cap,
            suggestedDisplayLabel: "alice",
            submitRequest: { _, _ in
                counter.bump()
                return outcome
            },
            groupRepository: repo
        )
        return Env(flow: flow, repo: repo, counter: counter)
    }

    // MARK: - Helpers

    private func makeGroup(groupID: Data, owner: IdentityID) -> ChatGroup {
        let hex = groupID.map { String(format: "%02x", $0) }.joined()
        return ChatGroup(
            id: hex,
            ownerIdentityID: owner,
            name: "Materialized group",
            groupSecret: Data(repeating: 0x55, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [],
            memberProfiles: [:],
            epoch: 0,
            salt: Data(repeating: 0x66, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: false
        )
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.02,
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("waitFor predicate never became true within \(timeout)s",
                file: file, line: line)
    }
}

// MARK: - State helpers

private extension JoinFlow.State {
    var isReady: Bool { if case .ready = self { return true } else { return false } }
    var isSending: Bool { if case .sending = self { return true } else { return false } }
    var isAwaitingApproval: Bool {
        if case .awaitingApproval = self { return true } else { return false }
    }
    var isApproved: Bool { if case .approved = self { return true } else { return false } }
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

// MARK: - Test doubles

private actor JoinTestableInMemoryGroupStore: GroupStore {
    private var rows: [String: ChatGroup] = [:]

    func preload(_ groups: [ChatGroup]) {
        for group in groups { rows[group.id] = group }
    }

    func list() -> [ChatGroup] {
        rows.values.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func insertOrUpdate(_ group: ChatGroup) -> Bool {
        let isNew = rows[group.id] == nil
        rows[group.id] = group
        return isNew
    }

    func markPublished(id: String, commitment: Data?) {
        guard var existing = rows[id] else { return }
        existing.isPublishedOnChain = true
        if let commitment { existing.commitment = commitment }
        rows[id] = existing
    }

    func delete(id: String) { rows.removeValue(forKey: id) }

    func deleteOwner(_ ownerIDString: String) {
        rows = rows.filter { $0.value.ownerIdentityID.rawValue.uuidString != ownerIDString }
    }
}
