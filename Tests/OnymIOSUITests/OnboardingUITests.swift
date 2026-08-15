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
    /// The smoke test below keeps the present → complete → persist
    /// contract guarded in the meantime.
    func test_onboardingWalk_allSevenSteps_thenNeverAgain() throws {
        throw XCTSkip("Superseded by the redesigned onboarding walk (tests PR of this stack).")
    }

    /// Minimal end-to-end smoke: the cover presents, the default path
    /// completes (recommended services; signed mandate; recovery
    /// deferred via "Remind me later"), Start dismisses onto the tab
    /// bar, and a relaunch without `--reset-keychain` proves the
    /// completion flag stuck. The full hub walk lands with the tests
    /// PR of this stack.
    func test_onboardingSmoke_defaultPathCompletes_thenNeverAgain() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-keychain",
            "--mock-biometric",
            "--ui-discovery",
            "--ui-onboarding",
            "--moderation-needs-consent",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        let onboarding = OnboardingScreen(app: app)

        // Welcome → identity. Identity's Continue is outcome-gated on
        // the key bootstrap; wait for it to unlock.
        XCTAssertTrue(onboarding.title("welcome").waitForExistence(timeout: 10),
                      "onboarding cover never presented. Hierarchy:\n\(app.debugDescription)")
        onboarding.continueFrom("welcome")
        XCTAssertTrue(onboarding.title("identity").waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilEnabled(onboarding.primary("identity"), timeout: 10),
                      "identity Continue never unlocked (bootstrap readiness)")
        onboarding.continueFrom("identity")

        // Services: keep the preselected recommended setup.
        onboarding.continueFrom("services")

        // Reports & safety: mandatory — sign the fixture authority's
        // mandate to unlock Continue.
        XCTAssertTrue(onboarding.title("moderation").waitForExistence(timeout: 5))
        let authorityRow = onboarding.moderationAuthorityRow(
            componentId: "onym:component:uitest-authority"
        )
        XCTAssertTrue(authorityRow.waitForExistence(timeout: 10),
                      "authority row never appeared. Hierarchy:\n\(app.debugDescription)")
        authorityRow.tap()
        XCTAssertTrue(onboarding.moderationAgree.waitForExistence(timeout: 5))
        onboarding.moderationAgree.tap()
        XCTAssertTrue(onboarding.moderationDone.waitForExistence(timeout: 10),
                      "mandate-signed state never appeared")
        onboarding.continueFrom("moderation")

        // Recovery: primary is gated on the reveal — defer instead.
        XCTAssertTrue(onboarding.title("recoveryPhrase").waitForExistence(timeout: 5))
        XCTAssertFalse(onboarding.primary("recoveryPhrase").isEnabled,
                       "\"I've written it down\" must stay disabled before the reveal")
        XCTAssertTrue(onboarding.skip("recoveryPhrase").waitForExistence(timeout: 5))
        onboarding.skip("recoveryPhrase").tap()

        // Done → Start messaging → tab bar.
        onboarding.continueFrom("done")
        let chats = ChatsScreen(app: app)
        XCTAssertTrue(chats.chatsTab.waitForExistence(timeout: 10),
                      "app never landed on the tab bar after onboarding")

        // Relaunch, same install, NO --reset-keychain: the completion
        // flag persisted, so the cover must not re-present.
        app.terminate()
        let second = XCUIApplication()
        second.launchArguments = [
            "--ui-testing",
            "--mock-biometric",
            "--ui-discovery",
            "--ui-onboarding",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        second.launch()
        XCTAssertTrue(ChatsScreen(app: second).chatsTab.waitForExistence(timeout: 10),
                      "relaunch never reached the tab bar")
        XCTAssertFalse(OnboardingScreen(app: second).title("welcome").exists,
                       "onboarding must not re-present once completed")
    }

    /// Polls `isEnabled` — XCUIElement has no built-in wait for
    /// enablement.
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists && element.isEnabled
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
