import XCTest

/// End-to-end coverage of the recovery-phrase backup flow, driven through
/// the live SwiftUI views via `XCUIApplication`. Every case launches a
/// fresh app instance so prior state never leaks across tests; XCTest
/// runs UI cases serially per-target by default, so no extra annotation
/// is needed to keep them off each other's toes.
///
/// The app under test reads three launch arguments (gated to `#if DEBUG`
/// in `OnymIOSApp`) so each case starts from a clean slate:
///   `--ui-testing`      flips the App into test wiring
///   `--reset-keychain`  wipes the test-isolated identity item
///   `--mock-biometric`  swaps in `AlwaysAcceptAuthenticator`
///
/// See `Support/AppLauncher.swift` and the page objects in `PageObjects/`
/// for the underlying mechanics.
///
/// Note: written in XCTest rather than Swift Testing because the
/// `Testing` module isn't wired into UI-test bundles by default in
/// Xcode 26. Unit tests in `OnymIOSTests` can still adopt Swift Testing
/// when its UI-bundle support lands.
final class RecoveryPhraseBackupUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Happy path

    /// Full happy path: open Backup → tap Reveal → see a 12-word phrase →
    /// answer all three verification rounds correctly → land on the Done
    /// screen.
    func test_happyPath_endToEnd() {
        let app = AppLauncher.launchFresh(language: "en")
        defer { app.terminate() }

        let settings = SettingsScreen(app: app)
        settings.tapBackupRecoveryPhrase()

        let intro = IntroScreen(app: app)
        intro.tapContinue()

        let reveal = RevealScreen(app: app)
        reveal.tapReveal()
        let phrase = reveal.capturedPhrase()
        XCTAssertEqual(phrase.count, 12)
        for word in phrase {
            XCTAssertFalse(word.isEmpty)
        }
        reveal.tapContinue()

        let verify = VerifyScreen(app: app)
        for round in 0..<3 {
            let position = verify.waitForRound()
            XCTAssertTrue((1...12).contains(position),
                          "round \(round): position \(position) out of 1…12")
            let correctWord = phrase[position - 1]
            verify.pick(word: correctWord)
        }

        let done = DoneScreen(app: app)
        XCTAssertTrue(done.waitForDisplayed(),
                      "Done screen never appeared after three correct picks")
    }

    // MARK: - Wrong word

    /// Picking a wrong word during verification keeps the user on the
    /// same round and surfaces the inline error message — no silent
    /// advance, no false-positive completion.
    func test_wrongWordPicked_keepsRound_andShowsError() {
        let app = AppLauncher.launchFresh(language: "en")
        defer { app.terminate() }

        SettingsScreen(app: app).tapBackupRecoveryPhrase()
        IntroScreen(app: app).tapContinue()

        let reveal = RevealScreen(app: app)
        reveal.tapReveal()
        let phrase = reveal.capturedPhrase()
        reveal.tapContinue()

        let verify = VerifyScreen(app: app)
        let position = verify.waitForRound()
        let correctWord = phrase[position - 1]
        verify.pickAnyWrongOption(correctWord: correctWord)

        XCTAssertTrue(verify.errorMessage.waitForExistence(timeout: 2),
                      "verify error message never appeared after wrong pick")
        XCTAssertEqual(verify.waitForRound(), position,
                       "round changed after wrong pick — should have stayed put")
    }

    // MARK: - Russian locale

    /// Launching with `language: "ru"` renders Russian copy on Settings
    /// (nav title + Backup row) and on the recovery-phrase Intro screen —
    /// confirms the localized catalog wires through end to end.
    func test_russianLocale_rendersRussianStrings() {
        let app = AppLauncher.launchFresh(language: "ru")
        defer { app.terminate() }

        // Chats is the default tab — drill into Settings before
        // asserting the Russian Settings copy exists.
        SettingsScreen(app: app).tapSettingsTab(timeout: 6)

        XCTAssertTrue(
            app.staticTexts["Настройки"].waitForExistence(timeout: 6),
            "Russian Settings nav title never appeared"
        )
        XCTAssertTrue(
            app.staticTexts["Резервная копия фразы восстановления"]
                .waitForExistence(timeout: 3),
            "Russian Backup row title never appeared"
        )

        SettingsScreen(app: app).tapBackupRecoveryPhrase()

        XCTAssertTrue(
            app.staticTexts["Ваша личность в 12 словах"]
                .waitForExistence(timeout: 3),
            "Russian intro hero title never appeared"
        )
    }

    // MARK: - Fresh launch

    /// A fresh-keychain launch generates a valid 12-word phrase: every
    /// word is non-empty, all-lowercase letters, and the phrase has at
    /// least 6 unique words (a sanity guard against a stuck/zeroed seed).
    func test_freshLaunch_generates12WordPhrase() {
        let app = AppLauncher.launchFresh(language: "en")
        defer { app.terminate() }

        SettingsScreen(app: app).tapBackupRecoveryPhrase()
        IntroScreen(app: app).tapContinue()

        let reveal = RevealScreen(app: app)
        reveal.tapReveal()
        let phrase = reveal.capturedPhrase()

        XCTAssertEqual(phrase.count, 12)
        XCTAssertGreaterThanOrEqual(
            Set(phrase).count, 6,
            "12-word phrase had \(Set(phrase).count) unique words — suspicious for a fresh BIP-39 seed"
        )
        for word in phrase {
            XCTAssertTrue(
                word.allSatisfy { $0.isLetter && $0.isLowercase },
                "phrase word `\(word)` is not all-lowercase letters"
            )
        }
    }
}
