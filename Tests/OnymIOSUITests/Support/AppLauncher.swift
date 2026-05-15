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
enum AppLauncher {
    static func launchFresh(language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-keychain",
            "--mock-biometric",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", localeIdentifier(for: language),
        ]
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
