import SwiftUI

@main
struct OnymIOSApp: App {
    private let dependencies: AppDependencies
    private let relayerRepository: RelayerRepository
    private let contractsRepository: ContractsRepository

    init() {
        let args = ProcessInfo.processInfo.arguments
        let repository: IdentityRepository
        let authenticator: BiometricAuthenticator
        #if DEBUG
        if let testMode = Self.resolveTestMode(args: args) {
            repository = testMode.repository
            authenticator = testMode.authenticator
        } else {
            repository = IdentityRepository.shared
            authenticator = LAContextAuthenticator()
        }
        #else
        repository = IdentityRepository.shared
        authenticator = LAContextAuthenticator()
        _ = args  // silence unused warning in Release
        #endif

        let relayerRepository = RelayerRepository(
            fetcher: GitHubReleasesKnownRelayersFetcher(),
            store: UserDefaultsRelayerSelectionStore()
        )
        self.relayerRepository = relayerRepository

        let contractsRepository = ContractsRepository(
            fetcher: GitHubReleasesContractsManifestFetcher(),
            store: UserDefaultsAnchorSelectionStore()
        )
        self.contractsRepository = contractsRepository

        self.dependencies = AppDependencies(
            makeRecoveryPhraseBackupFlow: { @MainActor in
                RecoveryPhraseBackupFlow(
                    repository: repository,
                    authenticator: authenticator
                )
            },
            makeRelayerSettingsFlow: { @MainActor in
                RelayerSettingsFlow(repository: relayerRepository)
            },
            makeAnchorsPickerFlow: { @MainActor in
                AnchorsPickerFlow(repository: contractsRepository)
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
                .task {
                    // Kick off both GitHub Releases fetches as soon as the
                    // app is on screen. Failures are silent; the user can
                    // still enter a custom relayer URL / pick an older
                    // contract from whatever was cached on the previous run.
                    await relayerRepository.start()
                    await contractsRepository.start()
                }
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
