import XCTest
@testable import OnymSettings

/// The Notifications screen's state machine: the toggle must never
/// claim more than what actually happened — authorization denied snaps
/// back, overlapping flips don't double-run, and "on" is distinguished
/// from "accepted by the backend".
@MainActor
final class NotificationsSettingsFlowTests: XCTestCase {
    func testDeniedAuthorizationSnapsBackAndSaysWhy() async {
        let flow = NotificationsSettingsFlow(
            isEnabled: false,
            enable: { false },
            disable: {}
        )

        await flow.setEnabled(true)

        XCTAssertFalse(flow.isEnabled)
        XCTAssertTrue(flow.authorizationDenied)
        XCTAssertFalse(flow.isWorking)
    }

    func testGrantedAuthorizationEnables() async {
        let flow = NotificationsSettingsFlow(
            isEnabled: false,
            enable: { true },
            disable: {}
        )

        await flow.setEnabled(true)

        XCTAssertTrue(flow.isEnabled)
        XCTAssertFalse(flow.authorizationDenied)
    }

    /// A flip while the previous flip is still working is dropped —
    /// two overlapping enables would prompt twice and register twice.
    func testReentrantSetEnabledIsDropped() async {
        let enableCalls = Counter()
        let gate = OneShotGate()
        let flow = NotificationsSettingsFlow(
            isEnabled: false,
            enable: {
                await enableCalls.increment()
                await gate.wait()
                return true
            },
            disable: {}
        )

        let first = Task { await flow.setEnabled(true) }
        // Let the first flip reach the suspension inside enable().
        await Task.yield()
        while await enableCalls.value == 0 { await Task.yield() }
        XCTAssertTrue(flow.isWorking)

        // Second flip while working: rejected without a second call.
        await flow.setEnabled(true)

        gate.open()
        await first.value

        let calls = await enableCalls.value
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(flow.isEnabled)
    }

    /// Turning off clears a stale denial note — it described a
    /// previous attempt, and the switch now honestly reads off.
    func testDisableClearsTheDenialNote() async {
        let denyFirst = Flag(true)
        let flow = NotificationsSettingsFlow(
            isEnabled: false,
            enable: {
                defer { denyFirst.value = false }
                return !denyFirst.value
            },
            disable: {}
        )
        await flow.setEnabled(true) // denied → note shows
        XCTAssertTrue(flow.authorizationDenied)

        await flow.setEnabled(true) // granted this time
        await flow.setEnabled(false) // an explicit off makes it stale
        XCTAssertFalse(flow.isEnabled)
        XCTAssertFalse(flow.authorizationDenied)
    }

    /// "On" is not "registered": the pending note tracks the injected
    /// probe on init, after each flip, and on explicit refresh.
    func testRegistrationPendingFollowsTheProbe() async {
        let pending = Flag(true)
        let flow = NotificationsSettingsFlow(
            isEnabled: true,
            enable: { true },
            disable: {},
            isRegistrationPending: { pending.value }
        )
        XCTAssertTrue(flow.registrationPending)

        pending.value = false
        flow.refreshRegistrationState()
        XCTAssertFalse(flow.registrationPending)

        pending.value = true
        await flow.setEnabled(false)
        XCTAssertTrue(flow.registrationPending)
    }

    /// The coordinator can disable underneath a still-mounted screen
    /// (authorization revoked in system Settings, app foregrounded
    /// back onto this view): the refresh re-reads the persisted opt-in
    /// through the injected closure instead of trusting the
    /// presentation-time snapshot.
    func testRefreshResyncsIsEnabledFromTheStore() async {
        let stored = Flag(true)
        let flow = NotificationsSettingsFlow(
            isEnabled: true,
            enable: { true },
            disable: {},
            readIsEnabled: { stored.value }
        )
        XCTAssertTrue(flow.isEnabled)

        // The coordinator disabled off-screen.
        stored.value = false
        flow.refreshRegistrationState()
        XCTAssertFalse(flow.isEnabled)

        // And a re-enable elsewhere reads back too.
        stored.value = true
        flow.refreshRegistrationState()
        XCTAssertTrue(flow.isEnabled)
    }
}

// MARK: - Small test actors

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A mutable box the @MainActor tests flip between reads.
@MainActor
private final class Flag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}
