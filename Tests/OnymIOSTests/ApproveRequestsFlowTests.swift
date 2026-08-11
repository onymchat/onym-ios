import XCTest
@testable import OnymIOS
@testable import OnymGroup

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

    func test_approve_routesToApproverAndClearsTheStaleError() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        flow.lastError = "stale error"

        await stub.setNextOutcome(.sent)
        flow.approve("req-1")

        // Waits on the call, not on the error clearing. The error is
        // dropped as the attempt *starts* now, so using it as a proxy for
        // "the call happened" would pass before the approver was ever
        // reached.
        try await waitForAsync { await stub.approveCalls == ["req-1"] }
        XCTAssertNil(flow.lastError)
    }

    func test_approve_clearsTheStaleErrorBeforeTheCallCompletes() async throws {
        // The row must never show a spinner over the previous failure —
        // "Anchoring on chain…" under "that didn't work" reads as a fresh
        // failure rather than a stale one.
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        flow.lastError = "that didn\u{2019}t work"
        flow.lastErrorRequestID = "req-1"

        await stub.setNextOutcome(.sent)
        flow.approve("req-1")

        XCTAssertNil(flow.lastError, "cleared synchronously, alongside the in-flight flag")
        XCTAssertTrue(flow.inFlightRequestIDs.contains("req-1"))
    }

    func test_approve_leavesAnotherRequestsErrorAlone() async throws {
        // Keying the error is what makes one row per request work:
        // retrying A must not wipe the failure still shown under B.
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        flow.lastError = "B failed"
        flow.lastErrorRequestID = "req-b"

        await stub.setNextOutcome(.sent)
        flow.approve("req-a")

        XCTAssertEqual(flow.lastError, "B failed")
        XCTAssertEqual(flow.lastErrorRequestID, "req-b")
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

        try await waitForAsync { await stub.declineCalls == ["req-1"] }
        XCTAssertNil(flow.lastError)
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
        // The success confirmation is no longer a banner on a modal —
        // it's the "Bob joined" system message the approve path writes
        // into the thread, exactly where the request row was.
    }

    /// The thread renders one row per pending request, so an error has
    /// to say *which* request it belongs to — otherwise a failure on one
    /// request paints red text under every other row on screen.
    func test_approve_failure_attributesErrorToThatRequest() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.emit([
            Self.makeRequest(id: "req-a", alias: "Ann"),
            Self.makeRequest(id: "req-b", alias: "Bob")
        ])
        await flow.start()
        try await waitFor { flow.pending.count == 2 }
        await stub.setNextOutcome(.anchorRejected("test"))

        flow.approve("req-b")
        try await waitFor { flow.lastError != nil }

        XCTAssertEqual(flow.lastErrorRequestID, "req-b",
                       "the error must be attributed to the request that failed")
    }

    /// Acting on one request must not wipe the error another row is
    /// still showing — the whole reason the error is keyed at all.
    func test_approvingOneRequest_leavesAnotherRequestsErrorIntact() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.emit([
            Self.makeRequest(id: "req-ok", alias: "Ann"),
            Self.makeRequest(id: "req-bad", alias: "Bob")
        ])
        await flow.start()
        try await waitFor { flow.pending.count == 2 }

        await stub.setNextOutcome(.anchorRejected("test"))
        flow.approve("req-bad")
        try await waitFor { flow.lastErrorRequestID == "req-bad" }

        await stub.setNextOutcome(.sent)
        flow.approve("req-ok")
        try await waitFor { !flow.isInFlight("req-ok") }

        XCTAssertEqual(flow.lastErrorRequestID, "req-bad",
                       "approving one request must not clear another's error")
        XCTAssertNotNil(flow.lastError)
    }

    func test_decliningOneRequest_leavesAnotherRequestsErrorIntact() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.emit([
            Self.makeRequest(id: "req-keep", alias: "Ann"),
            Self.makeRequest(id: "req-err", alias: "Bob")
        ])
        await flow.start()
        try await waitFor { flow.pending.count == 2 }

        await stub.setNextOutcome(.anchorRejected("test"))
        flow.approve("req-err")
        try await waitFor { flow.lastErrorRequestID == "req-err" }

        flow.decline("req-keep")
        try await waitFor { !flow.isInFlight("req-keep") }

        XCTAssertEqual(flow.lastErrorRequestID, "req-err",
                       "declining one request must not clear another's error")
    }

    func test_declineClearsAttributedError() async throws {
        let stub = StubApprover()
        let flow = ApproveRequestsFlow(approver: stub)
        await stub.emit([Self.makeRequest(id: "req-c", alias: "Cal")])
        await flow.start()
        try await waitFor { flow.pending.map(\.id).contains("req-c") }
        await stub.setNextOutcome(.anchorRejected("test"))
        flow.approve("req-c")
        try await waitFor { flow.lastErrorRequestID != nil }

        flow.decline("req-c")
        try await waitFor { flow.lastErrorRequestID == nil }
        XCTAssertNil(flow.lastError)
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
            joinerSendingPublicKey: Data(repeating: 0xEE, count: 32),
            joinerDisplayLabel: alias,
            groupId: Data(repeating: 0xBB, count: 32),
            groupName: "Family"
        )
    }

    /// Async-predicate variant, for waiting on actor state such as a
    /// stub's recorded calls.
    private func waitForAsync(
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.02,
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("Timed out waiting for predicate", file: file, line: line)
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
