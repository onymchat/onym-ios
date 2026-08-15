import Foundation
import XCTest
@testable import OnymOnboarding

/// UserDefaults round-trip with per-test suite isolation — same
/// pattern as `SeatSelectionStoreTests` in OnymDiscovery.
final class OnboardingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: UserDefaultsOnboardingStore!

    override func setUp() {
        super.setUp()
        suiteName = "app.onym.ios.onboarding.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsOnboardingStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    func testDefaultsToNotCompleted() {
        XCTAssertFalse(store.hasCompletedOnboarding())
    }

    func testMarkCompletedRoundTrips() {
        store.markOnboardingCompleted()
        XCTAssertTrue(store.hasCompletedOnboarding())
        // Idempotent.
        store.markOnboardingCompleted()
        XCTAssertTrue(store.hasCompletedOnboarding())
    }

    /// The app's `--reset-keychain` path clears this exact key; pin it
    /// so a rename can't silently orphan the reset.
    func testUsesTheDocumentedKey() {
        XCTAssertEqual(UserDefaultsOnboardingStore.key, "app.onym.ios.onboarding.completed")
        store.markOnboardingCompleted()
        XCTAssertTrue(defaults.bool(forKey: "app.onym.ios.onboarding.completed"))
    }

    /// The seam the app's `--reset-keychain` path calls — clears the
    /// flag without the app hardcoding the key string.
    func testResetOnboardingClearsTheFlag() {
        store.markOnboardingCompleted()
        store.resetOnboarding()
        XCTAssertFalse(store.hasCompletedOnboarding())
        XCTAssertNil(defaults.object(forKey: UserDefaultsOnboardingStore.key))
        // Idempotent on an already-clear store.
        store.resetOnboarding()
        XCTAssertFalse(store.hasCompletedOnboarding())
    }

    /// After a reset, the gate onboards again.
    func testResetReopensTheGate() {
        store.markOnboardingCompleted()
        store.resetOnboarding()
        XCTAssertTrue(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }

    // MARK: - Grandfathering probe truth table

    /// flag absent, no existing-user state → onboard.
    func testShouldOnboardWhenFreshInstall() {
        XCTAssertTrue(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }

    /// flag absent, but existing-user state (any hasUserInteracted or a
    /// mandate present) → grandfathered, no onboarding.
    func testShouldNotOnboardExistingUser() {
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { true }))
    }

    /// flag set, no existing-user state → no onboarding.
    func testShouldNotOnboardWhenCompleted() {
        store.markOnboardingCompleted()
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }

    /// flag set AND existing-user state → no onboarding.
    func testShouldNotOnboardWhenCompletedAndExisting() {
        store.markOnboardingCompleted()
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { true }))
    }

    /// The existing-user probe may be costly (keychain / mandate read):
    /// it must not run when the flag already answers the question.
    func testExistingUserProbeNotConsultedWhenFlagSet() {
        store.markOnboardingCompleted()
        var probed = false
        _ = OnboardingGate.shouldOnboard(store: store, isExistingUser: {
            probed = true
            return true
        })
        XCTAssertFalse(probed)
    }

    /// The probe is a pure read — grandfathering must not write the
    /// completion flag.
    func testProbeDoesNotWriteTheFlag() {
        _ = OnboardingGate.shouldOnboard(store: store, isExistingUser: { true })
        XCTAssertFalse(store.hasCompletedOnboarding())
    }

    // MARK: - Restart request (Settings → Restart Onboarding)

    func testRequestRestartSetsMarkerAndClearsCompleted() {
        store.markOnboardingCompleted()
        store.requestRestart()
        XCTAssertTrue(store.isRestartRequested())
        XCTAssertFalse(store.hasCompletedOnboarding())
        // Idempotent.
        store.requestRestart()
        XCTAssertTrue(store.isRestartRequested())
    }

    /// Completion ends the restart, however the walk was entered — the
    /// marker must not survive to re-open the gate on the next launch.
    func testMarkCompletedClearsRestartMarker() {
        store.requestRestart()
        store.markOnboardingCompleted()
        XCTAssertFalse(store.isRestartRequested())
        XCTAssertTrue(store.hasCompletedOnboarding())
        XCTAssertNil(defaults.object(forKey: UserDefaultsOnboardingStore.restartKey))
    }

    /// The app's `--reset-keychain` path clears BOTH documented keys.
    func testResetOnboardingClearsRestartMarkerToo() {
        XCTAssertEqual(
            UserDefaultsOnboardingStore.restartKey,
            "app.onym.ios.onboarding.restartRequested"
        )
        store.requestRestart()
        store.resetOnboarding()
        XCTAssertFalse(store.isRestartRequested())
        XCTAssertNil(defaults.object(forKey: UserDefaultsOnboardingStore.restartKey))
    }

    /// The substantive rule: an explicit restart OUTRANKS
    /// grandfathering. A configured user's state suppresses onboarding
    /// they never asked for — never onboarding they requested.
    func testRestartRequestOverridesGrandfathering() {
        store.requestRestart()
        XCTAssertTrue(OnboardingGate.shouldOnboard(store: store, isExistingUser: { true }))
    }

    /// A mid-walk kill resumes: the marker persists until completion,
    /// so the next cold boot's gate answers onboard again.
    func testRestartMarkerPersistsUntilCompletion() {
        store.requestRestart()
        // Simulate relaunch: a fresh store over the same defaults.
        let relaunched = UserDefaultsOnboardingStore(defaults: defaults)
        XCTAssertTrue(OnboardingGate.shouldOnboard(store: relaunched, isExistingUser: { true }))
        relaunched.markOnboardingCompleted()
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: relaunched, isExistingUser: { true }))
    }

    /// Cold-boot grandfathering for upgraders is untouched: without
    /// the marker, existing-user state still suppresses onboarding.
    func testGrandfatheringUnchangedWithoutRestartMarker() {
        XCTAssertFalse(store.isRestartRequested())
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { true }))
    }
}
