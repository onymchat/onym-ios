import XCTest
@testable import OnymIOS
import OnymOnboarding

/// The Settings → Restart Onboarding bridge: the action must present
/// the cover THIS session (the `pendingRestart` signal RootView
/// observes), persist the restart across a mid-walk kill, and override
/// the launch gate's grandfathering — all without touching identity,
/// chats, or the cold-boot behavior of users who never asked.
@MainActor
final class OnboardingRestartControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: UserDefaultsOnboardingStore!

    override func setUp() {
        super.setUp()
        suiteName = "app.onym.ios.onboarding.restart.tests.\(UUID().uuidString)"
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

    /// The Settings action's observable effect: `pendingRestart` is
    /// exactly the signal RootView presents the onboarding cover on.
    func test_requestRestart_raisesThePresentationSignal() {
        let controller = OnboardingRestartController(store: store)
        XCTAssertFalse(controller.pendingRestart)
        controller.requestRestart()
        XCTAssertTrue(controller.pendingRestart,
                      "the Settings action must raise the cover-presentation signal")
    }

    /// The persisted half: the marker is written and the completion
    /// flag cleared, so every reader of the store agrees a walk is due.
    func test_requestRestart_persistsMarkerAndClearsFlag() {
        store.markOnboardingCompleted()
        let controller = OnboardingRestartController(store: store)
        controller.requestRestart()
        XCTAssertTrue(store.isRestartRequested())
        XCTAssertFalse(store.hasCompletedOnboarding())
    }

    /// CRITICAL: a configured user (grandfathering probe answers
    /// "existing") must still onboard after an explicit restart — the
    /// probe suppresses onboarding nobody asked for, never onboarding
    /// the user requested.
    func test_requestRestart_overridesGrandfathering() {
        let controller = OnboardingRestartController(store: store)
        controller.requestRestart()
        XCTAssertTrue(
            OnboardingGate.shouldOnboard(store: store, isExistingUser: { true }),
            "restart must outrank the existing-user probe"
        )
    }

    /// Consuming the in-session signal (RootView presented the cover)
    /// must NOT clear the persisted marker: an app killed mid-walk
    /// resumes onboarding on the next launch.
    func test_consumeRestart_lowersSignalButKeepsMarker() {
        let controller = OnboardingRestartController(store: store)
        controller.requestRestart()
        controller.consumeRestart()
        XCTAssertFalse(controller.pendingRestart)
        XCTAssertTrue(store.isRestartRequested(),
                      "mid-walk kill must resume: the marker outlives the signal")
        // Simulated relaunch still onboards, grandfathering included.
        let relaunched = UserDefaultsOnboardingStore(defaults: defaults)
        XCTAssertTrue(OnboardingGate.shouldOnboard(store: relaunched, isExistingUser: { true }))
    }

    /// Completion (identical to a first run) closes everything: flag
    /// set, marker cleared, gate shut — for grandfathered and fresh
    /// users alike.
    func test_completion_endsTheRestart() {
        let controller = OnboardingRestartController(store: store)
        controller.requestRestart()
        controller.consumeRestart()
        store.markOnboardingCompleted()
        XCTAssertFalse(store.isRestartRequested())
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { true }))
        XCTAssertFalse(OnboardingGate.shouldOnboard(store: store, isExistingUser: { false }))
    }
}
