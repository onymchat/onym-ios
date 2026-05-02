import SwiftUI

@main
struct OnymIOSApp: App {
    private let dependencies: AppDependencies
    private let identityRepository: IdentityRepository
    private let relayerRepository: RelayerRepository
    private let contractsRepository: ContractsRepository
    private let groupRepository: GroupRepository

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

        let relayerRepository: RelayerRepository
        let contractsRepository: ContractsRepository
        #if DEBUG
        if args.contains("--ui-testing") {
            relayerRepository = RelayerRepository(
                fetcher: UITestKnownRelayersFetcher(),
                store: UITestRelayerSelectionStore()
            )
            contractsRepository = ContractsRepository(
                fetcher: UITestContractsManifestFetcher(),
                store: UITestAnchorSelectionStore()
            )
        } else {
            relayerRepository = RelayerRepository(
                fetcher: GitHubReleasesKnownRelayersFetcher(),
                store: UserDefaultsRelayerSelectionStore()
            )
            contractsRepository = ContractsRepository(
                fetcher: GitHubReleasesContractsManifestFetcher(),
                store: UserDefaultsAnchorSelectionStore()
            )
        }
        #else
        relayerRepository = RelayerRepository(
            fetcher: GitHubReleasesKnownRelayersFetcher(),
            store: UserDefaultsRelayerSelectionStore()
        )
        contractsRepository = ContractsRepository(
            fetcher: GitHubReleasesContractsManifestFetcher(),
            store: UserDefaultsAnchorSelectionStore()
        )
        #endif
        self.identityRepository = repository
        self.relayerRepository = relayerRepository
        self.contractsRepository = contractsRepository

        // Group repository — falls back to in-memory if the on-disk
        // store can't open (rare; FileProtection / sandbox issues).
        // Failure here is non-fatal for the create-group flow, just
        // means newly-created groups don't survive a relaunch.
        let groupRepository: GroupRepository
        if let store = try? SwiftDataGroupStore() {
            groupRepository = GroupRepository(store: store)
        } else {
            groupRepository = GroupRepository(store: SwiftDataGroupStore.inMemory())
        }
        self.groupRepository = groupRepository

        // Inbox transport for invitation send. Connects on first use
        // via `RootView.task`.
        let inboxTransport = NostrInboxTransport(
            signerProvider: OnymNostrSignerProvider()
        )

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
            },
            makeCreateGroupFlow: { @MainActor in
                CreateGroupFlow(interactor: CreateGroupInteractor(
                    identity: repository,
                    relayers: relayerRepository,
                    contracts: contractsRepository,
                    groups: groupRepository,
                    inboxTransport: inboxTransport
                ))
            },
            makeChatsFlow: { @MainActor in
                ChatsFlow(repository: groupRepository)
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
                .task {
                    // Bootstrap the identity eagerly so flows that need it
                    // (Create Group, invitation seal, …) don't fail with
                    // `.missingIdentity` if the user never opens the
                    // Backup screen first. Idempotent: a second call after
                    // success is a no-op. Failure is silent — the next
                    // operation that needs identity will surface a clear
                    // error to the user.
                    _ = try? await identityRepository.bootstrap()
                    // Kick off both GitHub Releases fetches as soon as the
                    // app is on screen. Failures are silent; the user can
                    // still enter a custom relayer URL / pick an older
                    // contract from whatever was cached on the previous run.
                    await relayerRepository.start()
                    await contractsRepository.start()
                    // Replay groups for the in-memory snapshot stream.
                    await groupRepository.reload()
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
