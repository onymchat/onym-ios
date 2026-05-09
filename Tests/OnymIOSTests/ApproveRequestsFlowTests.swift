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

    // MARK: - PR 14 in-flight state

    func test_approve_marksInFlight_thenClearsOnCompletion() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.setHoldApprove(true)
        await stub.setNextOutcome(.sent)
        await stub.emit([Self.makeRequest(id: "req-flight", alias: "Bob")])
        await flow.start()
        try await waitFor { flow.pending.map(\.id).contains("req-flight") }

        flow.approve("req-flight")
        // Synchronously after the intent fires, the ID should be
        // recorded as in-flight (the .insert happens on the @MainActor
        // before the Task hits any suspension point).
        try await waitFor { flow.isInFlight("req-flight") }

        await stub.releaseApprove()
        try await waitFor { !flow.isInFlight("req-flight") }
        XCTAssertNil(flow.lastError, ".sent outcome must clear lastError")
        // PR 15: success banner shows the joiner's alias.
        XCTAssertEqual(flow.lastSuccessMessage, "Bob is now in the group.")
    }

    func test_approve_successBanner_autoDismissesAfter3s() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.setNextOutcome(.sent)
        await stub.emit([Self.makeRequest(id: "req-toast", alias: "Bob")])
        await flow.start()
        try await waitFor { flow.pending.map(\.id).contains("req-toast") }

        flow.approve("req-toast")
        try await waitFor { flow.lastSuccessMessage != nil }
        // Wait a touch over 3s for the auto-dismiss task.
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertNil(flow.lastSuccessMessage,
                     "success banner must auto-dismiss after ~3s")
    }

    func test_approve_failureClearsAnyPriorSuccessBanner() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        flow.lastSuccessMessage = "stale success"
        await stub.emit([Self.makeRequest(id: "req-fail-bus", alias: "Bob")])
        await flow.start()
        try await waitFor { flow.pending.map(\.id).contains("req-fail-bus") }
        await stub.setNextOutcome(.anchorRejected("test"))

        flow.approve("req-fail-bus")
        try await waitFor { flow.lastError != nil }
        XCTAssertNil(flow.lastSuccessMessage,
                     "failure must clear any leftover success banner")
    }

    func test_approve_secondTapWhileInFlight_isNoop() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.setHoldApprove(true)

        flow.approve("req-debounce")
        try await waitFor { flow.isInFlight("req-debounce") }
        // Second tap during in-flight is debounced — must not call
        // `approver.approve` again.
        flow.approve("req-debounce")
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await stub.approveCalls
        XCTAssertEqual(calls, ["req-debounce"],
                       "second tap during in-flight must be a no-op")

        await stub.releaseApprove()
        try await waitFor { !flow.isInFlight("req-debounce") }
    }

    func test_approve_clearsInFlight_evenOnFailure() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.setHoldApprove(true)
        await stub.setNextOutcome(.anchorRejected("test reject"))

        flow.approve("req-fail")
        try await waitFor { flow.isInFlight("req-fail") }

        await stub.releaseApprove()
        try await waitFor { !flow.isInFlight("req-fail") }
        XCTAssertNotNil(flow.lastError,
                        "failure must populate lastError so the banner shows")
    }

    func test_decline_marksInFlight_thenClears() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.setHoldDecline(true)

        flow.decline("req-dec")
        try await waitFor { flow.isInFlight("req-dec") }

        await stub.releaseDecline()
        try await waitFor { !flow.isInFlight("req-dec") }
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
            joinerLeafHash: Data(repeating: 0xDD, count: 32),
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

    /// PR 14: optional gate so tests can hold `approve` / `decline`
    /// in flight to assert the flow's `inFlightRequestIDs` state.
    /// Default is "complete immediately" (matches PR 13's fast-path
    /// tests). Polling-based instead of continuation-based to avoid
    /// the test/stub setup race where `release` could fire before
    /// the held call had stored its continuation.
    private var holdApprove: Bool = false
    private var holdDecline: Bool = false

    func setHoldApprove(_ hold: Bool) { holdApprove = hold }
    func setHoldDecline(_ hold: Bool) { holdDecline = hold }

    func releaseApprove() { holdApprove = false }
    func releaseDecline() { holdDecline = false }

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
        while holdApprove {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nextOutcome
    }

    func decline(requestId: String) async {
        declineCalls.append(requestId)
        while holdDecline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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
