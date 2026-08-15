import XCTest

/// End-to-end walk of the first-launch onboarding cover under
/// `--ui-onboarding` + `--ui-discovery`: all seven steps, offline and
/// deterministic.
///
/// The discovery fakes serve the byte-pinned OnymDiscovery conformance
/// fixtures with the repository clock parked in the fixtures' validity
/// window (2026-08-14; snapshot expiry 2026-09-12 can't rot the test),
/// so step 2's TOFU confirm and step 3's module-consent walk run the
/// full production trust pipeline. The moderation fakes serve the
/// canned UITest Authority; `--moderation-needs-consent` starts the
/// mandate store empty so step 6 exercises the real pick → review →
/// sign path (mandatory: the directory has an entry, so Continue stays
/// locked until the mandate is signed).
///
/// A second launch WITHOUT `--reset-keychain` then proves persistence:
/// the completion flag survives, and the cover never re-presents even
/// though `--ui-onboarding` is still passed.
final class OnboardingUITests: XCTestCase {

    /// The redesigned walk (welcome → identity → services hub →
    /// moderation → recovery phrase → done) lands with the tests PR
    /// (stack 3/3); the old seven-step walk no longer matches the
    /// flow, so it is skipped here rather than left red for bisects.
    func test_onboardingWalk_allSevenSteps_thenNeverAgain() throws {
        throw XCTSkip("Superseded by the redesigned onboarding walk (tests PR of this stack).")
    }

    /// `--skip-onboarding` outranks `--ui-onboarding`: launch a fresh
    /// install with BOTH flags (same posture as the walk test plus the
    /// veto) and the cover must never present. Passing both is what
    /// pins the veto's precedence — with `--ui-onboarding` absent the
    /// gate's first conjunct already yields false and the test would
    /// pass even without the veto.
    func test_skipOnboarding_neverPresentsCover() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-keychain",
            "--mock-biometric",
            "--ui-discovery",
            "--ui-onboarding",
            "--skip-onboarding",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        let chats = ChatsScreen(app: app)
        XCTAssertTrue(chats.chatsTab.waitForExistence(timeout: 10),
                      "app never reached the tab bar")
        XCTAssertFalse(OnboardingScreen(app: app).title("welcome").exists,
                       "onboarding must not present under --skip-onboarding")
    }
}
