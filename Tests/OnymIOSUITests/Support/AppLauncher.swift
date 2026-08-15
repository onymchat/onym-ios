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
enum AppLauncher {
    static func launchFresh(discovery: Bool = false, language: String = "en") -> XCUIApplication {
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
