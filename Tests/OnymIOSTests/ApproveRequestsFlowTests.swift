import XCTest
@testable import OnymIOS

@MainActor
final class ApproveRequestsFlowTests: XCTestCase {

    // MARK: - Stream propagation

    func test_start_subscribesAndMirrorsApproverStream() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await flow.start()

        await stub.emit([Self.makeRequest(id: "req-1", alias: "alice")])
        try await waitFor { flow.pending.map(\.id) == ["req-1"] }
        XCTAssertEqual(flow.pending.first?.joinerDisplayLabel, "alice")
    }

    func test_start_isIdempotent_secondCallDoesNotDoubleSubscribe() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await flow.start()
        await flow.start()
        let started = await stub.startCalls
        XCTAssertEqual(started, 1, "start() must dedupe at the flow level")
    }

    // MARK: - Approve

    func test_approve_routesToApproverAndClearsErrorOnSent() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        flow.lastError = "stale error"

        await stub.setNextOutcome(.sent)
        flow.approve("req-1")
        try await waitFor { flow.lastError == nil }
        let calls = await stub.approveCalls
        XCTAssertEqual(calls, ["req-1"])
    }

    func test_approve_setsErrorOnTransportFailure() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)

        await stub.setNextOutcome(.transportFailed("relay rejected"))
        flow.approve("req-2")
        try await waitFor { flow.lastError != nil }
        XCTAssertTrue(flow.lastError?.contains("relay rejected") ?? false,
                      "lastError = \(flow.lastError ?? "nil")")
    }

    func test_approve_setsErrorOnUnknownGroup() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)

        await stub.setNextOutcome(.unknownGroup)
        flow.approve("req-3")
        try await waitFor { flow.lastError != nil }
        XCTAssertEqual(
            flow.lastError,
            "This invite isn\u{2019}t for any group on this device."
        )
    }

    // MARK: - Decline

    func test_decline_routesToApproverAndClearsError() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        flow.lastError = "leftover"

        flow.decline("req-1")
        try await waitFor { flow.lastError == nil }
        let calls = await stub.declineCalls
        XCTAssertEqual(calls, ["req-1"])
    }

    // MARK: - Misc

    func test_dismissError_clearsLastError() {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        flow.lastError = "boom"
        flow.dismissError()
        XCTAssertNil(flow.lastError)
    }

    // MARK: - Helpers

    private static func makeRequest(
        id: String,
        alias: String
    ) -> JoinRequestApprover.PendingRequest {
        JoinRequestApprover.PendingRequest(
            id: id,
            joinerInboxPublicKey: Data(repeating: 0xAA, count: 32),
            joinerBlsPublicKey: Data(repeating: 0xCC, count: 48),
            joinerDisplayLabel: alias,
            groupId: Data(repeating: 0xBB, count: 32),
            groupName: "Family"
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
        XCTFail("Timed out waiting for predicate", file: file, line: line)
    }
}

// MARK: - Stub

private actor StubApprover: JoinRequestApproving {
    private var continuations: [UUID: AsyncStream<[JoinRequestApprover.PendingRequest]>.Continuation] = [:]
    private var snapshot: [JoinRequestApprover.PendingRequest] = []

    private(set) var approveCalls: [String] = []
    private(set) var declineCalls: [String] = []
    private(set) var startCalls: Int = 0
    private var nextOutcome: JoinRequestApprover.ApproveOutcome = .sent

    func emit(_ requests: [JoinRequestApprover.PendingRequest]) {
        snapshot = requests
        for c in continuations.values { c.yield(requests) }
    }

    func setNextOutcome(_ outcome: JoinRequestApprover.ApproveOutcome) {
        nextOutcome = outcome
    }

    nonisolated var pending: AsyncStream<[JoinRequestApprover.PendingRequest]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    func start() async {
        startCalls += 1
    }

    func approve(requestId: String) async -> JoinRequestApprover.ApproveOutcome {
        approveCalls.append(requestId)
        return nextOutcome
    }

    func decline(requestId: String) async {
        declineCalls.append(requestId)
    }

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<[JoinRequestApprover.PendingRequest]>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(snapshot)
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
