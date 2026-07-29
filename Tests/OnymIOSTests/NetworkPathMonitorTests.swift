import XCTest
@testable import OnymIOS

/// Unit tests for `ConnectivityRegainDetector` — the emission policy
/// behind `NetworkPathMonitor`. Covers the review's headline concern:
/// a launch-offline start must still fire on the first genuine regain.
final class NetworkPathMonitorTests: XCTestCase {
    func testBaselineCallbackNeverEmits() {
        let d = ConnectivityRegainDetector(cooldown: 0)
        XCTAssertFalse(d.shouldEmit(satisfied: true), "first (baseline) callback must not emit")
    }

    func testEmitsOnUnsatisfiedToSatisfiedEdge() {
        let d = ConnectivityRegainDetector(cooldown: 0)
        XCTAssertFalse(d.shouldEmit(satisfied: false)) // baseline (offline start)
        XCTAssertTrue(d.shouldEmit(satisfied: true), "offline→online must emit")
    }

    func testOfflineLaunchThenRegainEmits() {
        // The exact bug the reviewer flagged: launch offline, connectivity
        // arrives — the regain must not be swallowed.
        let d = ConnectivityRegainDetector(cooldown: 0)
        _ = d.shouldEmit(satisfied: false) // baseline, offline
        XCTAssertTrue(d.shouldEmit(satisfied: true))
    }

    func testSatisfiedToSatisfiedChurnDoesNotEmit() {
        let d = ConnectivityRegainDetector(cooldown: 0)
        _ = d.shouldEmit(satisfied: true)  // baseline, online
        XCTAssertFalse(d.shouldEmit(satisfied: true), "interface churn while satisfied must not emit")
        XCTAssertFalse(d.shouldEmit(satisfied: true))
    }

    func testFlappingIsDebouncedWithinCooldown() {
        var now = Date(timeIntervalSince1970: 1_000)
        let d = ConnectivityRegainDetector(cooldown: 3, now: { now })
        _ = d.shouldEmit(satisfied: true)              // baseline online

        now = now.addingTimeInterval(0.1)
        XCTAssertTrue(d.shouldEmit(satisfied: false) == false)
        XCTAssertTrue(d.shouldEmit(satisfied: true), "first regain emits")

        // A rapid flap within the cooldown window is coalesced away.
        now = now.addingTimeInterval(0.5)
        _ = d.shouldEmit(satisfied: false)
        XCTAssertFalse(d.shouldEmit(satisfied: true), "regain within cooldown is suppressed")

        // After the cooldown lapses, a regain emits again.
        now = now.addingTimeInterval(5)
        _ = d.shouldEmit(satisfied: false)
        XCTAssertTrue(d.shouldEmit(satisfied: true), "regain after cooldown emits")
    }
}
