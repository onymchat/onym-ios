import XCTest
@testable import OnymModeration

/// The gate-check cadence arithmetic (DeviceCheck profile §5) as a
/// pure-function table: success serves the result, unreachable serves
/// the last known state inside the grace window, and every degraded
/// path lands on blocking — never on unmoderated operation.
final class GateCheckDeriveTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let policy = GateCheckPolicy.default

    private func banState() -> BanState {
        BanState(verdictRef: "verdict-1", authorityContact: "appeals@authority.example")
    }

    // MARK: - Refused

    func testRefusedBlocksNowButKeepsPersistedState() {
        let persisted = PersistedGateState(
            lastResult: .clear,
            lastSuccessAt: now.addingTimeInterval(-60)
        )
        let (status, kept) = GateCheckRepository.derive(
            persisted: persisted,
            attempt: .refused,
            now: now,
            policy: policy
        )
        // A reachable backend's refusal blocks immediately — the grace
        // window is for network conditions, not for a 401 — but the
        // persisted state is kept so a later good check overwrites.
        XCTAssertEqual(status, .gateCheckRequired(.backendRefused))
        XCTAssertEqual(kept, persisted)
    }

    // MARK: - Success

    func testSuccessClearIsOperationalAndPersists() {
        let (status, persisted) = GateCheckRepository.derive(
            persisted: nil,
            attempt: .success(.clear),
            now: now,
            policy: policy
        )
        XCTAssertEqual(status, .operational(openCases: []))
        XCTAssertEqual(persisted, PersistedGateState(lastResult: .clear, lastSuccessAt: now))
    }

    func testSuccessBannedBlocks() {
        let (status, _) = GateCheckRepository.derive(
            persisted: nil,
            attempt: .success(.banned(banState())),
            now: now,
            policy: policy
        )
        XCTAssertEqual(status, .banned(banState()))
    }

    func testSuccessCheckRequiredBlocks() {
        let (status, _) = GateCheckRepository.derive(
            persisted: nil,
            attempt: .success(.checkRequired(.reidentificationRequired)),
            now: now,
            policy: policy
        )
        XCTAssertEqual(status, .gateCheckRequired(.reidentificationRequired))
    }

    // MARK: - Unreachable

    func testUnreachableWithNoHistoryBlocks() {
        let (status, persisted) = GateCheckRepository.derive(
            persisted: nil,
            attempt: .unreachable,
            now: now,
            policy: policy
        )
        XCTAssertEqual(status, .gateCheckRequired(.neverChecked))
        XCTAssertNil(persisted)
    }

    func testUnreachableInsideGraceServesLastKnownState() {
        let lastSuccess = now.addingTimeInterval(-policy.offlineGrace)  // boundary: exactly P3D ago
        let persisted = PersistedGateState(lastResult: .clear, lastSuccessAt: lastSuccess)
        let (status, kept) = GateCheckRepository.derive(
            persisted: persisted,
            attempt: .unreachable,
            now: now,
            policy: policy
        )
        XCTAssertEqual(status, .operational(openCases: []))
        XCTAssertEqual(kept, persisted)
    }

    func testUnreachablePastGraceBlocks() {
        let lastSuccess = now.addingTimeInterval(-policy.offlineGrace - 1)
        let persisted = PersistedGateState(lastResult: .clear, lastSuccessAt: lastSuccess)
        let (status, kept) = GateCheckRepository.derive(
            persisted: persisted,
            attempt: .unreachable,
            now: now,
            policy: policy
        )
        XCTAssertEqual(status, .gateCheckRequired(.offlineGraceExpired))
        // Persisted state kept: a later success overwrites, and the
        // stale record is inert (no conforming path serves it past
        // grace).
        XCTAssertEqual(kept, persisted)
    }

    func testUnreachableInsideGraceServesLastKnownBan() {
        // Grace never launders a ban: the last known state is what's
        // served, whatever it was.
        let persisted = PersistedGateState(
            lastResult: .banned(banState()),
            lastSuccessAt: now.addingTimeInterval(-86_400)
        )
        let (status, _) = GateCheckRepository.derive(
            persisted: persisted,
            attempt: .unreachable,
            now: now,
            policy: policy
        )
        XCTAssertEqual(status, .banned(banState()))
    }

    // MARK: - Persistence round-trip

    func testGateStateStoreRoundTripsResultKinds() throws {
        let suite = "gate-derive-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsGateStateStore(defaults: defaults)

        let notice = CaseNotice(
            caseId: "case-1",
            authority: "onym:component:authority",
            accused: "onym:key:user",
            mandateRef: "aa",
            classId: "csam",
            evidenceSummary: "hash:evidence",
            responseDeadline: now.addingTimeInterval(3 * 86_400),
            decisionDeadline: now.addingTimeInterval(7 * 86_400),
            signature: "sig"
        )
        for result in [
            GateCheckResult.clear,
            .caseOpen([notice]),
            .banned(banState()),
            .checkRequired(.tokenInvalid),
        ] {
            let state = PersistedGateState(lastResult: result, lastSuccessAt: now)
            store.save(state)
            XCTAssertEqual(store.load(), state)
        }

        store.save(nil)
        XCTAssertNil(store.load())
    }
}
