import XCTest

/// Boots `OnymIOS` with a fresh test-isolated keychain + a mock biometric
/// authenticator so the UI test never blocks on a Face ID prompt and never
/// inherits state from a previous test.
///
/// Launch arguments honoured by the app under `#if DEBUG`:
///   `--ui-testing`      Required to flip the App into test wiring.
///   `--reset-keychain`  Wipe the test-isolated `app.onym.ios.identity.uitests`
///                       keychain item before bootstrap.
///   `--mock-biometric`  Swap `LAContextAuthenticator` for a stub that returns
///                       success immediately without prompting.
///
/// `language` flips Apple's `-AppleLanguages` / `-AppleLocale` user-defaults
/// so the same test can exercise localized strings.
///
/// `discovery: true` adds `--ui-discovery`, wiring the discovery
/// surface to offline fixture fakes (see `UITestDiscoveryFakes.swift`
/// in the app target). Default `false` keeps discovery nil — the
/// pre-existing `--ui-testing` behavior — so existing call sites and
/// tests are untouched.
///
/// Every launch passes `--skip-onboarding`, so "this suite runs
/// without onboarding" is DECLARED in the launch arguments rather
/// than being an incidental consequence of the factory's nil default
/// — a future change to the app's default can't silently put a cover
/// in front of every existing test. Onboarding suites don't come
/// through this factory: they build their own argument lists (see
/// `OnboardingUITests`), because the walk needs `--ui-onboarding`
/// plus step-specific flags.
enum AppLauncher {
    static func launchFresh(
        discovery: Bool = false,
        language: String = "en"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-keychain",
            "--mock-biometric",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", localeIdentifier(for: language),
        ]
        if discovery {
            app.launchArguments.append("--ui-discovery")
        }
        app.launchArguments.append("--skip-onboarding")
        app.launch()
        return app
    }

    private static func localeIdentifier(for language: String) -> String {
        switch language {
        case "ru": return "ru_RU"
        default:   return "en_US"
        }
    }
}
