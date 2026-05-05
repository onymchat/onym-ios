import SwiftUI

@main
struct OnymIOSApp: App {
    private let dependencies: AppDependencies
    private let identityRepository: IdentityRepository
    private let relayerRepository: RelayerRepository
    private let contractsRepository: ContractsRepository
    private let groupRepository: GroupRepository
    private let inboxTransport: any InboxTransport
    private let incomingInvitations: IncomingInvitationsRepository
    private let introKeyStore: any IntroKeyStore
    private let introRequestStore: any IntroRequestStore

    /// Captured intro capability from a Universal Link or custom-
    /// scheme deeplink (`https://onym.chat/join?c=…` /
    /// `onym://join?c=…`). Drives a `.sheet(item:)` over RootView —
    /// PR-6 surfaces a placeholder; PR-7 will replace it with the
    /// real `JoinView` + `JoinFlow`.
    @State private var pendingCapability: IntroCapability?

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
        self.inboxTransport = inboxTransport

        // Incoming invitations repository — falls back to in-memory if
        // the on-disk store can't open (same protection-class concerns
        // as `SwiftDataGroupStore`).
        let invitationStore: any InvitationStore =
            (try? SwiftDataInvitationStore()) ?? SwiftDataInvitationStore.inMemory()
        self.incomingInvitations = IncomingInvitationsRepository(store: invitationStore)

        // Per-invite ephemeral X25519 keys for the Level-2 deeplink
        // invite flow. Keychain-backed in production; survives across
        // launches so an outstanding invite link can still be served.
        let introKeyStore = KeychainIntroKeyStore()
        let inviteIntroducer = InviteIntroducer(store: introKeyStore)
        self.introKeyStore = introKeyStore
        // Process-lifetime sink for inbound "request to join"
        // envelopes. The sender-approval UI (PR-5+) consumes this.
        self.introRequestStore = InMemoryIntroRequestStore()

        // Single shared IdentitiesFlow so the toolbar picker on Chats
        // and the Settings → Identities screen observe the same state.
        let identitiesFlow = IdentitiesFlow(repository: repository)

        // Single shared JoinRequestApprover + ApproveRequestsFlow.
        // The collector inside the approver subscribes to
        // `IntroRequestStore` once and keeps a decoded snapshot in
        // memory; the @Observable flow mirrors that snapshot so the
        // toolbar badge on Chats and the modal request list see the
        // same state without re-running decryption.
        let joinRequestApprover = JoinRequestApprover(
            identity: repository,
            introKeyStore: introKeyStore,
            introRequestStore: self.introRequestStore,
            groupRepository: groupRepository,
            inboxTransport: inboxTransport
        )
        let approveRequestsFlow = ApproveRequestsFlow(approver: joinRequestApprover)

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
            makeShareInviteFlow: { @MainActor in
                ShareInviteFlow(
                    identity: repository,
                    introducer: inviteIntroducer,
                    groupRepository: groupRepository
                )
            },
            makeJoinFlow: { @MainActor capability in
                let sender = JoinRequestSender(
                    identity: repository,
                    inboxTransport: inboxTransport
                )
                return JoinFlow(
                    capability: capability,
                    suggestedDisplayLabel: "alice",  // PR-7+: derive from active identity
                    submitRequest: { cap, label in
                        await sender.send(
                            capability: cap,
                            joinerDisplayLabel: label
                        )
                    },
                    groupRepository: groupRepository
                )
            },
            makeChatsFlow: { @MainActor in
                ChatsFlow(repository: groupRepository)
            },
            identitiesFlow: identitiesFlow,
            approveRequestsFlow: approveRequestsFlow
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
                    // Start the approver collector eagerly so the
                    // Chats toolbar badge reflects pending requests
                    // from the moment the app is on screen, even
                    // before the user opens the modal request list.
                    // Idempotent — `ChatsView.task` calls it too.
                    await dependencies.approveRequestsFlow.start()
                    // Kick off both GitHub Releases fetches as soon as the
                    // app is on screen. Failures are silent; the user can
                    // still enter a custom relayer URL / pick an older
                    // contract from whatever was cached on the previous run.
                    await relayerRepository.start()
                    await contractsRepository.start()
                    // Replay groups + invitations for the in-memory snapshot streams.
                    await groupRepository.reload()
                    await incomingInvitations.reload()
                    // Wire identity selection → group + invitations filter
                    // so both lists flip when the user switches identity.
                    if let initialID = await identityRepository.currentSelectedID() {
                        await groupRepository.setCurrentIdentity(initialID)
                        await incomingInvitations.setCurrentIdentity(initialID)
                    }
                }
                .task {
                    // Long-lived listener: forward every selection change
                    // to the per-identity-filtered repositories.
                    for await id in identityRepository.currentIdentityID {
                        await groupRepository.setCurrentIdentity(id)
                        await incomingInvitations.setCurrentIdentity(id)
                    }
                }
                .task {
                    // Long-lived listener: wipe identity-scoped state
                    // when an identity is removed (the secrets are
                    // already gone — this clears chats + invitations
                    // from disk so cross-identity bleed-through is
                    // impossible).
                    for await removed in identityRepository.identityRemoved {
                        await groupRepository.removeForOwner(removed)
                        await incomingInvitations.removeForOwner(removed)
                        // Cascade-wipe the removed identity's intro
                        // privkeys so an attacker who restores a
                        // backup post-removal can't decrypt
                        // outstanding intro requests.
                        await introKeyStore.deleteForOwner(removed)
                    }
                }
                .task {
                    // PR-4: subscribe to every identity's inbox
                    // concurrently. Without this, messages addressed
                    // to a non-current identity drop on the floor.
                    //
                    // Each inbound message is decrypted at receive
                    // time by the dispatcher; member-roster
                    // announcements apply directly to
                    // `GroupRepository.memberProfiles`, everything
                    // else falls through to the invitations queue.
                    let dispatcher = IncomingMessageDispatcher(
                        envelopeDecrypter: identityRepository,
                        groupRepository: groupRepository,
                        invitationsRepository: incomingInvitations
                    )
                    let fanout = InboxFanoutInteractor(
                        inboxTransport: inboxTransport,
                        identityRepository: identityRepository,
                        dispatcher: dispatcher
                    )
                    await fanout.run()
                }
                .task {
                    // Level-2 deeplink intro pump. Subscribes to one
                    // Nostr inbox tag per outstanding invite link
                    // owned by the current identity; switching identity
                    // re-balances the subscription set automatically.
                    // No per-identity dedup map — multiple simultaneous
                    // identities each get their own pump if they each
                    // have outstanding invites. We start with the
                    // current identity only; when the user switches,
                    // the outer task restarts via .task { } onChange
                    // semantics in a follow-up. For V1, single-active-
                    // identity pump is sufficient.
                    let pump = IntroInboxPump(
                        inboxTransport: inboxTransport,
                        store: introRequestStore
                    )
                    // Re-resolve the active identity on each emission
                    // and re-subscribe to its entries stream.
                    var currentTask: Task<Void, Never>?
                    for await activeID in identityRepository.currentIdentityID {
                        currentTask?.cancel()
                        guard let activeID else {
                            currentTask = nil
                            continue
                        }
                        let entries = introKeyStore.entriesStream(forOwner: activeID)
                        currentTask = Task { await pump.run(entries: entries) }
                    }
                    currentTask?.cancel()
                }
                .onOpenURL { url in
                    // Custom URL scheme (`onym://join?c=…`) and
                    // Universal Link cold-start both surface here on
                    // SwiftUI 4+. The allowlist in DeeplinkCapture
                    // guards against forged ACTION_VIEW analogues.
                    if let cap = DeeplinkCapture.introCapability(from: url) {
                        pendingCapability = cap
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal Link warm-start (e.g. backgrounded
                    // app foregrounded by tapping a link in
                    // Messages). On modern iOS `.onOpenURL` typically
                    // covers this too, but the dual handler matches
                    // Apple's documented best-practice and removes
                    // a class of "did the link tap arrive?" bugs.
                    if let cap = DeeplinkCapture.introCapability(from: activity.webpageURL) {
                        pendingCapability = cap
                    }
                }
                .sheet(item: $pendingCapability) { cap in
                    // PR-7: replace PR-6's placeholder with the real
                    // join flow. Construct the JoinFlow lazily per
                    // sheet entry — re-tapping a fresh link should
                    // start a clean state machine.
                    JoinView(
                        flow: dependencies.makeJoinFlow(cap),
                        onClose: { pendingCapability = nil }
                    )
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
        let keychain = IdentityKeychainStore(testNamespace: "uitests")
        if args.contains("--reset-keychain") {
            try? keychain.wipeAll()
            // Also clear the "selected identity" UserDefault so each
            // UI test boots into the same first-launch shape.
            UserDefaults.standard.removeObject(forKey: "chat.onym.ios.identity.selectedID")
        }
        let repo = IdentityRepository(keychain: keychain)
        let auth: BiometricAuthenticator = args.contains("--mock-biometric")
            ? AlwaysAcceptAuthenticator()
            : LAContextAuthenticator()
        return (repo, auth)
    }
}
#endif
