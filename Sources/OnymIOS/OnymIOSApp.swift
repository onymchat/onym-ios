import SwiftUI

@main
struct OnymIOSApp: App {
    private let repository: IdentityRepository
    private let authenticator: BiometricAuthenticator

    init() {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if let testMode = Self.resolveTestMode(args: args) {
            self.repository = testMode.repository
            self.authenticator = testMode.authenticator
            return
        }
        #endif
        self.repository = IdentityRepository.shared
        self.authenticator = LAContextAuthenticator()
        _ = args  // silence unused warning in Release
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                repository: repository,
                authenticator: authenticator
            )
        }
    }
}

#if DEBUG
extension OnymIOSApp {
    /// Resolves UI-test launch arguments into the dependencies the App
    /// should use. Returns `nil` when not under UI test, in which case the
    /// production wiring runs.
    ///
    /// Recognised args (only honoured when `--ui-testing` is also present):
    ///   `--reset-keychain`    Wipes the test-isolated keychain on launch
    ///                         so each test starts from a clean slate.
    ///   `--mock-biometric`    Swaps in `AlwaysAcceptAuthenticator` so the
    ///                         flow doesn't block on a real Face ID prompt
    ///                         (the simulator can't pass one).
    ///
    /// All UI-test runs use a separate Keychain service
    /// (`chat.onym.ios.identity.uitests`) so they never touch the user's
    /// real identity even on a developer machine.
    fileprivate static func resolveTestMode(
        args: [String]
    ) -> (repository: IdentityRepository, authenticator: BiometricAuthenticator)? {
        guard args.contains("--ui-testing") else { return nil }
        let keychain = KeychainStore(
            service: "chat.onym.ios.identity.uitests",
            account: "current"
        )
        if args.contains("--reset-keychain") {
            try? keychain.wipe()
        }
        let repo = IdentityRepository(keychain: keychain)
        let auth: BiometricAuthenticator = args.contains("--mock-biometric")
            ? AlwaysAcceptAuthenticator()
            : LAContextAuthenticator()
        return (repo, auth)
    }
}
#endif
