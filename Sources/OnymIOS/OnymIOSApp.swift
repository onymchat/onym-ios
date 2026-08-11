import SwiftUI
import OnymTransport
import OnymChain
import OnymIdentity
import OnymTransportBlossom
import OnymTransportNostr
import OnymGroup
import OnymPersistence
import OnymChatsCore
import OnymInbox
import OnymRecovery
import OnymChatsUI
import OnymSettings
import OnymModeration
import OnymModerationUI

@main
struct OnymIOSApp: App {
    private let dependencies: AppDependencies
    private let identityRepository: IdentityRepository
    private let relayerRepository: RelayerRepository
    private let contractsRepository: ContractsRepository
    private let groupRepository: GroupRepository
    private let messageRepository: MessageRepository
    private let imageLoader: ChatImageLoader
    private let videoLoader: ChatVideoLoader
    private let voiceLoader: ChatVoiceLoader
    private let inboxTransport: any InboxTransport
    private let nostrRelaysRepository: NostrRelaysRepository
    private let blossomServersRepository: BlossomServersRepository
    private let incomingInvitations: IncomingInvitationsRepository
    private let pendingInvitesStore: PendingInvitesStore
    private let pendingVerificationStore: PendingVerificationStore
    private let groupStateVerifier: GroupStateVerifier
    private let introKeyStore: any IntroKeyStore
    private let introRequestStore: any IntroRequestStore
    /// Moderation seat: authority designation + mandate lifecycle,
    /// and the DeviceCheck gate-check cadence. The enforcement
    /// backend is a stub until one is deployed.
    private let moderationRepository: ModerationRepository
    private let gateCheckRepository: GateCheckRepository
    /// Factory for the per-request SEP contract transport. Normally
    /// `URLSessionSEPContractTransport`; swapped for an in-memory
    /// ledger-backed fake under `--ui-loopback` so a Tyranny group
    /// anchors + verifies offline in UI tests.
    private let contractTransportFactory: @Sendable (URL) -> any SEPContractTransport
    /// DEBUG-only: a deeplink URL passed via `--open-url <url>` (with
    /// `--ui-testing`). Surfaced as `pendingCapability` at launch so a
    /// UI test can drive the Join flow without Safari.
    private let initialDeeplinkURL: URL?

    /// Captured intro capability from a Universal Link or custom-
    /// scheme deeplink (`https://onym.app/join?c=…` /
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

        // Moderation seat. Authorities are swappable data (a signed
        // directory + per-authority manifests); the enforcement
        // backend is the deployed interface service — only UI tests
        // keep `StubEnforcementBackendClient`, answering the gate per
        // `--moderation-scenario`.
        let moderationSigner = IdentityModerationSigner(repository: repository)
        let moderationRepository: ModerationRepository
        let gateCheckRepository: GateCheckRepository
        let moderationManifestFetcher: any AuthorityManifestFetcher
        #if DEBUG
        // Simulator has no DeviceCheck (`DCDevice.isSupported` is
        // false there), and the deployed interface answers a
        // token-less session `check_required(attestationUnavailable)`
        // — so a Simulator run against the production service can
        // only ever show the blocking screen. Simulator builds
        // therefore default the moderation seat to the same stubs as
        // UI-testing mode (gate clear, seeded mandate); the
        // UI-testing flags that shape those stubs still apply, and
        // `--enforcement-base-url` still opts into the real loop
        // against a local deployment. Compile-time-gated: a simulator
        // binary cannot run on a device, so this can't ship.
        #if targetEnvironment(simulator)
        let stubModerationSeat = args.contains("--ui-testing")
            || Self.resolveEnforcementBaseURL(args: args) == nil
        #else
        let stubModerationSeat = args.contains("--ui-testing")
        #endif
        if stubModerationSeat {
            let backend = StubEnforcementBackendClient(
                scenario: Self.resolveModerationScenario(args: args)
            )
            moderationManifestFetcher = UITestAuthorityManifestFetcher()
            moderationRepository = ModerationRepository(
                authoritiesFetcher: UITestKnownAuthoritiesFetcher(),
                manifestFetcher: moderationManifestFetcher,
                mandateStore: UITestMandateStore(
                    seeded: !args.contains("--moderation-needs-consent")
                ),
                backend: backend,
                authorityClients: StubModerationAuthorityClientFactory(),
                attestation: UITestDeviceAttestationProvider(),
                signer: moderationSigner
            )
            gateCheckRepository = GateCheckRepository(
                attestation: UITestDeviceAttestationProvider(),
                backend: backend,
                moderation: moderationRepository,
                signer: moderationSigner,
                store: UITestGateStateStore(),
                // Scenario fixtures are stage props (sentinel
                // signatures, fixed refs), not authenticated
                // artifacts; validating them would strip the ban
                // screen's verdict rows in every `banned` scenario.
                validatesBanVerdicts: false
            )
        } else {
            // `--enforcement-base-url <https-url>` points a dev build
            // at a local reference deployment (https only — reach a
            // local server through an https tunnel/proxy). Without it,
            // dev builds talk to the production service like release
            // builds do.
            let backend = URLSessionEnforcementBackendClient(
                baseURL: Self.resolveEnforcementBaseURL(args: args)
                    ?? URLSessionEnforcementBackendClient.defaultBaseURL
            )
            moderationManifestFetcher = URLSessionAuthorityManifestFetcher()
            moderationRepository = ModerationRepository(
                authoritiesFetcher: GitHubReleasesKnownAuthoritiesFetcher(),
                manifestFetcher: moderationManifestFetcher,
                mandateStore: UserDefaultsMandateStore(),
                backend: backend,
                authorityClients: URLSessionModerationAuthorityClientFactory(
                    signer: moderationSigner
                ),
                attestation: DCDeviceAttestationProvider(),
                signer: moderationSigner
            )
            gateCheckRepository = GateCheckRepository(
                attestation: DCDeviceAttestationProvider(),
                backend: backend,
                moderation: moderationRepository,
                signer: moderationSigner,
                store: UserDefaultsGateStateStore()
            )
        }
        #else
        let moderationBackend = URLSessionEnforcementBackendClient()
        moderationManifestFetcher = URLSessionAuthorityManifestFetcher()
        moderationRepository = ModerationRepository(
            authoritiesFetcher: GitHubReleasesKnownAuthoritiesFetcher(),
            manifestFetcher: moderationManifestFetcher,
            mandateStore: UserDefaultsMandateStore(),
            backend: moderationBackend,
            authorityClients: URLSessionModerationAuthorityClientFactory(
                signer: moderationSigner
            ),
            attestation: DCDeviceAttestationProvider(),
            signer: moderationSigner
        )
        gateCheckRepository = GateCheckRepository(
            attestation: DCDeviceAttestationProvider(),
            backend: moderationBackend,
            moderation: moderationRepository,
            signer: moderationSigner,
            store: UserDefaultsGateStateStore()
        )
        #endif
        self.moderationRepository = moderationRepository
        self.gateCheckRepository = gateCheckRepository

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

        // Chat messages — same fall-back policy as `groupRepository`
        // (on-disk store with in-memory fallback if FileProtection /
        // sandbox blocks the file). Separate `Messages.store` keeps
        // schema migrations from cross-domain wipes.
        let messageRepository: MessageRepository
        if let store = try? SwiftDataMessageStore() {
            messageRepository = MessageRepository(store: store)
        } else {
            messageRepository = MessageRepository(store: SwiftDataMessageStore.inMemory())
        }
        self.messageRepository = messageRepository

        // Inbox transport for invitation send. The endpoint list comes
        // from `NostrRelaysRepository` — read at app boot in the
        // WindowGroup .task before the fanout interactor starts. The
        // transport itself is just a Nostr-WebSocket client; nothing
        // here picks the URL.
        // UI-test loopback wiring (`--ui-loopback`): swap the Nostr
        // transport for an in-process loopback and the relayer/chain
        // round-trip for an in-memory ledger, so two on-device
        // identities exchange messages and a Tyranny group anchors +
        // verifies with no network. No-op in Release / normal runs.
        let inboxTransport: any InboxTransport
        let contractTransportFactory: @Sendable (URL) -> any SEPContractTransport
        #if DEBUG
        if args.contains("--ui-loopback") {
            inboxTransport = UITestLoopbackInboxTransport()
            let ledger = UITestChainLedger()
            contractTransportFactory = { _ in UITestSEPContractTransport(ledger: ledger) }
        } else {
            inboxTransport = NostrInboxTransport(signerProvider: OnymNostrSignerProvider())
            contractTransportFactory = { url in
                URLSessionSEPContractTransport(endpoint: url, authToken: RelayerSecrets.authToken)
            }
        }
        #else
        inboxTransport = NostrInboxTransport(signerProvider: OnymNostrSignerProvider())
        contractTransportFactory = { url in
            URLSessionSEPContractTransport(endpoint: url, authToken: RelayerSecrets.authToken)
        }
        #endif
        self.inboxTransport = inboxTransport
        self.contractTransportFactory = contractTransportFactory

        // DEBUG deeplink injection for UI tests (see `initialDeeplinkURL`).
        #if DEBUG
        if args.contains("--ui-testing"),
           let flagIndex = args.firstIndex(of: "--open-url"),
           flagIndex + 1 < args.count {
            self.initialDeeplinkURL = URL(string: args[flagIndex + 1])
        } else {
            self.initialDeeplinkURL = nil
        }
        #else
        self.initialDeeplinkURL = nil
        #endif

        // User-configurable Blossom servers (Settings → Transport →
        // Blossom Relays). Constructing the repository seeds the store on
        // first launch, so reading it back synchronously here yields the
        // effective server list. Uploads/downloads target the first
        // configured server; changes apply on the next launch (the client
        // base URL is chosen once here).
        let blossomStore = UserDefaultsBlossomServersSelectionStore()
        // No network fetch under the UI harness — the hardcoded seed
        // stays the default so tests are deterministic + offline.
        let blossomFetcher: (any KnownBlossomServersFetcher)?
        #if DEBUG
        blossomFetcher = args.contains("--ui-loopback") || args.contains("--ui-testing")
            ? nil : GitHubReleasesKnownBlossomServersFetcher()
        #else
        blossomFetcher = GitHubReleasesKnownBlossomServersFetcher()
        #endif
        let blossomServersRepository = BlossomServersRepository(
            store: blossomStore,
            fetcher: blossomFetcher
        )
        self.blossomServersRepository = blossomServersRepository
        let blossomBaseURL = blossomStore.load().endpoints.first?.url
            ?? URLSessionBlossomClient.defaultBaseURL

        // Blossom client + image loader for image messages. Swapped for
        // an in-memory store under `--ui-loopback` so image send/receive
        // round-trips with no network; one shared instance so the loader
        // can read back what the sender uploaded.
        let blossomClient: any BlossomClient
        #if DEBUG
        if args.contains("--ui-loopback") {
            blossomClient = UITestBlossomClient()
        } else {
            blossomClient = URLSessionBlossomClient(
                baseURL: blossomBaseURL,
                signerProvider: OnymNostrSignerProvider()
            )
        }
        #else
        blossomClient = URLSessionBlossomClient(
            baseURL: blossomBaseURL,
            signerProvider: OnymNostrSignerProvider()
        )
        #endif
        let imageLoader = ChatImageLoader(blossomClient: blossomClient)
        self.imageLoader = imageLoader
        let videoLoader = ChatVideoLoader(blossomClient: blossomClient)
        self.videoLoader = videoLoader
        let voiceLoader = ChatVoiceLoader(blossomClient: blossomClient)
        self.voiceLoader = voiceLoader

        // Video encoder for outgoing videos. The real encoder runs
        // AVFoundation transcoding; under `--ui-loopback` (which can't
        // transcode a real clip on CI) swap in a canned encoding so the
        // send pipeline still exercises seal → upload → fan-out.
        let videoEncoder: @Sendable (URL) async -> ChatVideoEncoder.Encoded?
        #if DEBUG
        if args.contains("--ui-loopback") {
            videoEncoder = { _ in Self.debugTestVideoEncoded() }
        } else {
            videoEncoder = ChatVideoEncoder.encode(fromVideoURL:)
        }
        #else
        videoEncoder = ChatVideoEncoder.encode(fromVideoURL:)
        #endif

        // Voice encoder for outgoing voice messages. Same harness swap as
        // the video encoder — the loopback harness can't read a real
        // recording, so a canned clip drives seal → upload → fan-out.
        let voiceEncoder: @Sendable (URL) async -> ChatVoiceEncoder.Encoded?
        #if DEBUG
        if args.contains("--ui-loopback") {
            voiceEncoder = { _ in Self.debugTestVoiceEncoded() }
        } else {
            voiceEncoder = ChatVoiceEncoder.encode(fromAudioURL:)
        }
        #else
        voiceEncoder = ChatVoiceEncoder.encode(fromAudioURL:)
        #endif

        // Outbox: persists sealed media blobs so a failed send can be
        // resent (survives app restart) by re-uploading the exact bytes.
        let chatOutbox = ChatOutbox()

        // Nostr-relays config — drives the inbox transport's
        // connections + the Settings → Transport → Nostr screen.
        // First-launch path inside the actor seeds with the Onym
        // Official relay; subsequent launches honor the user's
        // persisted list.
        let nostrFetcher: (any KnownNostrRelaysFetcher)?
        #if DEBUG
        nostrFetcher = args.contains("--ui-loopback") || args.contains("--ui-testing")
            ? nil : GitHubReleasesKnownNostrRelaysFetcher()
        #else
        nostrFetcher = GitHubReleasesKnownNostrRelaysFetcher()
        #endif
        let nostrRelaysRepository = NostrRelaysRepository(
            store: UserDefaultsNostrRelaysSelectionStore(),
            fetcher: nostrFetcher
        )
        self.nostrRelaysRepository = nostrRelaysRepository

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
        // Durable sink for inbound "request to join" envelopes. The
        // request now renders as a row inside the founder's chat
        // thread, so it has to survive a relaunch the way any other
        // message does — an in-memory store would silently drop it on
        // force-quit while the joiner sat on "Waiting for the host to
        // approve…". Falls back to the in-memory store if the on-disk
        // container can't be opened, so a storage failure degrades to
        // the old behaviour instead of blocking launch.
        self.introRequestStore = (try? SwiftDataIntroRequestStore())
            ?? InMemoryIntroRequestStore()

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
            inboxTransport: inboxTransport,
            relayers: relayerRepository,
            contracts: contractsRepository,
            makeContractTransport: contractTransportFactory,
            // Gives the admin its own "X joined" row on approve. Every
            // other member's copy comes from the fanned-out
            // announcement, which the admin never receives.
            systemEvents: ChatSystemEventRecorder(messageRepository: messageRepository)
        )
        let approveRequestsFlow = ApproveRequestsFlow(approver: joinRequestApprover)

        // Invitee-side push invitations. The dispatcher records decoded
        // `GroupInviteOfferPayload`s here; the flow drives the Chats
        // "Invitations" surface and, on explicit Accept, ships a
        // `JoinRequestPayload` to the offer's intro key via a sender
        // identical to the deeplink join path.
        let pendingInvitesStore = PendingInvitesStore()
        self.pendingInvitesStore = pendingInvitesStore
        // Verify-at-current (Option 2): stale snapshots defer here; the
        // verifier asks the admin for current state and surfaces a
        // "couldn't verify" state if the admin is offline.
        let pendingVerificationStore = PendingVerificationStore()
        self.pendingVerificationStore = pendingVerificationStore
        let groupStateVerifier = GroupStateVerifier(
            identity: repository,
            inboxTransport: inboxTransport,
            groupRepository: groupRepository,
            store: pendingVerificationStore
        )
        self.groupStateVerifier = groupStateVerifier
        let pendingInvitesSender = JoinRequestSender(
            identity: repository,
            inboxTransport: inboxTransport
        )
        // Admin-side group-photo broadcaster — applies locally + fans a
        // GroupAvatarPayload to members. Shared actor; the change-photo
        // UI calls it through `AppDependencies.setGroupAvatar`.
        let groupAvatarBroadcaster = GroupAvatarBroadcaster(
            identity: repository,
            inboxTransport: inboxTransport,
            groupRepository: groupRepository
        )
        let pendingInvitesFlow = PendingInvitesFlow(
            store: pendingInvitesStore,
            verificationStore: pendingVerificationStore,
            groupRepository: groupRepository,
            submitJoin: { cap, label in
                await pendingInvitesSender.send(
                    capability: cap,
                    joinerDisplayLabel: label
                )
            },
            displayLabel: { @MainActor [identitiesFlow] in
                identitiesFlow.identities
                    .first { $0.id == identitiesFlow.currentID }?
                    .name ?? ""
            },
            retryVerification: { [groupStateVerifier] groupIDHex in
                await groupStateVerifier.retry(groupIDHex: groupIDHex)
            }
        )

        let moderationGateFlow = ModerationGateFlow(
            moderation: moderationRepository,
            gateCheck: gateCheckRepository
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
            makeNostrRelaySettingsFlow: { @MainActor in
                NostrRelaySettingsFlow(repository: nostrRelaysRepository)
            },
            makeBlossomRelaySettingsFlow: { @MainActor in
                BlossomRelaySettingsFlow(repository: blossomServersRepository)
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
                    inboxTransport: inboxTransport,
                    introducer: inviteIntroducer,
                    makeContractTransport: contractTransportFactory
                ))
            },
            makeShareInviteFlow: { @MainActor in
                ShareInviteFlow(
                    identity: repository,
                    introducer: inviteIntroducer,
                    groupRepository: groupRepository
                )
            },
            makeJoinFlow: { @MainActor [identitiesFlow] capability in
                let sender = JoinRequestSender(
                    identity: repository,
                    inboxTransport: inboxTransport
                )
                // Pre-fill with the active identity's alias so the
                // joiner sees a sensible default. Empty string when
                // `identitiesFlow` hasn't populated yet (cold-start
                // race) — JoinView's TextField placeholder + the
                // disabled Send button prompt the user to type
                // something in.
                let activeName = identitiesFlow.identities
                    .first { $0.id == identitiesFlow.currentID }?
                    .name ?? ""
                return JoinFlow(
                    capability: capability,
                    suggestedDisplayLabel: activeName,
                    submitRequest: { cap, label in
                        await sender.send(
                            capability: cap,
                            joinerDisplayLabel: label
                        )
                    },
                    groupRepository: groupRepository
                )
            },
            chatsFlow: ChatsFlow(repository: groupRepository, messages: messageRepository),
            identitiesFlow: identitiesFlow,
            approveRequestsFlow: approveRequestsFlow,
            pendingInvitesFlow: pendingInvitesFlow,
            messageRepository: messageRepository,
            imageLoader: imageLoader,
            videoLoader: videoLoader,
            voiceLoader: voiceLoader,
            sendMessageInteractor: SendMessageInteractor(
                identity: repository,
                inboxTransport: inboxTransport,
                messageRepository: messageRepository,
                groupRepository: groupRepository,
                blossomClient: blossomClient,
                blossomServerURL: blossomBaseURL.absoluteString,
                videoEncoder: videoEncoder,
                voiceEncoder: voiceEncoder,
                outbox: chatOutbox,
                imageLoader: imageLoader
            ),
            chatReceiptSender: ChatReceiptSender(
                identity: repository,
                inboxTransport: inboxTransport
            ),
            setGroupAvatar: { groupIDHex, jpeg in
                await groupAvatarBroadcaster.setAvatar(groupIDHex: groupIDHex, jpeg: jpeg)
            },
            setGroupName: { groupIDHex, name in
                await groupAvatarBroadcaster.setName(groupIDHex: groupIDHex, name: name)
            },
            moderationGateFlow: moderationGateFlow,
            makeModerationConsentFlow: { @MainActor mode in
                ModerationConsentFlow(
                    mode: mode,
                    repository: moderationRepository,
                    onConsented: { moderationGateFlow.consentCompleted() }
                )
            },
            makeModerationSettingsFlow: { @MainActor in
                ModerationSettingsFlow(
                    repository: moderationRepository,
                    gateCheck: gateCheckRepository
                )
            },
            makeModerationReportView: { @MainActor message in
                AnyView(ModerationReportView(flow: ModerationReportFlow(
                    message: message,
                    repository: moderationRepository
                )))
            },
            makeModerationCaseFlow: { @MainActor notice in
                ModerationCaseFlow(
                    caseId: notice.caseId,
                    mandateRef: notice.mandateRef,
                    repository: moderationRepository
                )
            },
            makeModerationBanCaseFlow: { @MainActor caseId, mandateRef in
                ModerationCaseFlow(
                    caseId: caseId,
                    mandateRef: mandateRef,
                    repository: moderationRepository,
                    banContext: true
                )
            },
            makeModerationRecoveryCaseFlow: { @MainActor caseId in
                guard let record = await moderationRepository.activeMandateRecord(),
                      let mandateRef = try? record.mandate.mandateHash()
                else { return nil }
                return ModerationCaseFlow(
                    caseId: caseId,
                    mandateRef: mandateRef,
                    repository: moderationRepository,
                    banContext: true
                )
            },
            lookupModerationRecoveryCaseIDs: { @MainActor in
                (try? await moderationRepository.recoverableCaseIDs()) ?? []
            },
            makeDeviceRecoveryFlow: { @MainActor in
                // A resolvable key scopes the persisted claim to the
                // identity that signed it. When no key resolves, the
                // empty grantee matches no stored claim, and filing
                // surfaces the signer's error on the form.
                let grantee = (try? await moderationSigner.userKeyID()) ?? ""
                return DeviceRecoveryFlow(
                    claimStore: UserDefaultsRecoveryClaimStore(),
                    grantee: grantee,
                    fileClaim: { contact, statement in
                        try await moderationRepository.fileDeviceRecoveryClaim(
                            contact: contact,
                            statement: statement
                        )
                    },
                    claimStatus: { claimId in
                        try await moderationRepository.deviceRecoveryClaimStatus(claimId: claimId)
                    },
                    redeem: { grant in
                        await gateCheckRepository.redeemRecoveryGrant(grant)
                    }
                )
            }
        )
    }

    #if DEBUG
    /// `--enforcement-base-url <url>` (with a DEBUG build): point the
    /// enforcement backend client at a local deployment for driving
    /// the full moderation loop in development. The client enforces
    /// https in every build; a non-https URL fails every request with
    /// `insecureBaseURL`.
    private static func resolveEnforcementBaseURL(args: [String]) -> URL? {
        guard let flagIndex = args.firstIndex(of: "--enforcement-base-url"),
              args.indices.contains(flagIndex + 1) else { return nil }
        return URL(string: args[flagIndex + 1])
    }

    /// `--moderation-scenario clear|case-open|banned|check-required`
    /// (with `--ui-testing`): which canned world the stub enforcement
    /// backend answers, so UI tests can drive the ban screen, the
    /// open-case banner, and the gate-required screen deterministically.
    private static func resolveModerationScenario(
        args: [String]
    ) -> StubEnforcementBackendClient.Scenario {
        guard let flagIndex = args.firstIndex(of: "--moderation-scenario"),
              flagIndex + 1 < args.count,
              let scenario = StubEnforcementBackendClient.Scenario(rawValue: args[flagIndex + 1])
        else { return .clear }
        return scenario
    }

    /// Canned `ChatVideoEncoder.Encoded` for the UI-test video-send path:
    /// a real poster (from the shared test JPEG) plus small placeholder
    /// MP4 bytes. The test only asserts the poster renders + round-trips;
    /// playback isn't exercised, so the bytes needn't be a playable clip.
    static func debugTestVideoEncoded() -> ChatVideoEncoder.Encoded? {
        guard let poster = ChatImageEncoder.encode(
            fromImageData: ChatThreadView.debugTestImageData()
        ) else { return nil }
        return ChatVideoEncoder.Encoded(
            mp4: Data("uitest-video-blob".utf8),
            width: poster.width,
            height: poster.height,
            durationSeconds: 3,
            poster: poster
        )
    }

    static func debugTestVoiceEncoded() -> ChatVoiceEncoder.Encoded? {
        // A canned clip for the loopback harness — the bytes only need to
        // round-trip through seal → upload → fan-out; a ramped waveform
        // gives the bubble something to render.
        let waveform = (0..<ChatVoiceEncoder.waveformBarCount).map { i in
            UInt8((Double(i) / Double(ChatVoiceEncoder.waveformBarCount) * 255).rounded())
        }
        return ChatVoiceEncoder.Encoded(
            m4a: Data("uitest-voice-blob".utf8),
            durationSeconds: 4,
            waveform: waveform
        )
    }
    #endif

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
                    // Eagerly populate the shared identities flow so a
                    // cold-start deeplink (which constructs JoinFlow
                    // before any tab's `.task` has fired) can read the
                    // active identity's alias for `suggestedDisplayLabel`.
                    // Idempotent — Chats / Settings tabs call this too.
                    await dependencies.identitiesFlow.start()
                    // Start the approver collector eagerly so the
                    // Chats toolbar badge reflects pending requests
                    // from the moment the app is on screen, even
                    // before the user opens the modal request list.
                    // Idempotent — `ChatsView.task` calls it too.
                    await dependencies.approveRequestsFlow.start()
                    // Start the invitee-side invitations flow eagerly so
                    // the Chats toolbar badge reflects offers from the
                    // moment the app is on screen. Idempotent.
                    await dependencies.pendingInvitesFlow.start()
                    // Start the verifier's group watcher so a pending
                    // verification resolves the moment its fresh snapshot
                    // materializes.
                    await groupStateVerifier.start()
                    // Kick off both GitHub Releases fetches as soon as the
                    // app is on screen. Failures are silent; the user can
                    // still enter a custom relayer URL / pick an older
                    // contract from whatever was cached on the previous run.
                    await relayerRepository.start()
                    await contractsRepository.start()
                    // Refresh the Nostr + Blossom default lists from the
                    // published GitHub manifests (no-op offline / under the
                    // UI harness — the hardcoded seed stays the default).
                    await nostrRelaysRepository.start()
                    await blossomServersRepository.start()
                    // Moderation: refresh the designated-authorities
                    // directory and begin the gate-check cadence
                    // (launch check + P1D interval). Runs after
                    // identity bootstrap above so gate sessions can
                    // carry an identity signature.
                    await moderationRepository.start()
                    await gateCheckRepository.start()
                    // Install the selected-identity filters before replaying
                    // persisted snapshots. Reloading first publishes through
                    // a nil filter, so a ChatsFlow that subscribes during
                    // cold start can permanently receive an empty initial
                    // list until the view is recreated (Settings → back).
                    if let initialID = await identityRepository.currentSelectedID() {
                        await groupRepository.setCurrentIdentity(initialID)
                        await incomingInvitations.setCurrentIdentity(initialID)
                        await pendingInvitesStore.setCurrentIdentity(initialID)
                        await pendingVerificationStore.setCurrentIdentity(initialID)
                    }
                    // Replay groups + invitations only after their identity
                    // filters are ready, so every startup subscriber sees
                    // the persisted rows for the active identity.
                    await groupRepository.reload()
                    await incomingInvitations.reload()
                }
                .task {
                    // Long-lived listener: forward every selection change
                    // to the per-identity-filtered repositories.
                    for await id in identityRepository.currentIdentityID {
                        await groupRepository.setCurrentIdentity(id)
                        await incomingInvitations.setCurrentIdentity(id)
                        await pendingInvitesStore.setCurrentIdentity(id)
                        await pendingVerificationStore.setCurrentIdentity(id)
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
                        await pendingInvitesStore.removeForOwner(removed)
                        await pendingVerificationStore.removeForOwner(removed)
                        // Cascade-wipe the removed identity's intro
                        // privkeys so an attacker who restores a
                        // backup post-removal can't decrypt
                        // outstanding intro requests.
                        await introKeyStore.deleteForOwner(removed)
                        // Filed-report ledger rows are keyed by the
                        // reporter's `onym:key:` reference, not by
                        // IdentityID (and the removed identity's keys
                        // are already gone) — so purge by keeping only
                        // the reporters that still exist locally.
                        // Skip the purge entirely if the identity list
                        // can't be read: an empty keep-set would wipe
                        // every identity's ledger, not just the
                        // removed one's.
                        if let remaining = try? await identityRepository.currentIdentities() {
                            let keys = Set(remaining.map { summary in
                                "onym:key:" + summary.sendingPublicKey
                                    .map { String(format: "%02x", $0) }.joined()
                            })
                            await moderationRepository.purgeReportRecords(
                                keepingReporters: keys
                            )
                            await moderationRepository.purgeCaseStatusRecords(
                                keepingUsers: keys
                            )
                            await moderationRepository.purgeCaseSubmissionRecords(
                                keepingUsers: keys
                            )
                        }
                    }
                }
                .task {
                    // Connect the Nostr inbox transport to every
                    // configured relay BEFORE the fanout interactor
                    // attempts to subscribe. Without this, both legs
                    // of the inbox are silently dead: subscribe()
                    // no-ops on an empty connections dict and send()
                    // throws TransportError.notConnected.
                    let endpoints = await nostrRelaysRepository
                        .currentEndpoints()
                        .map { TransportEndpoint(url: $0.url) }
                    await inboxTransport.connect(to: endpoints)

                    // PR-4: subscribe to every identity's inbox
                    // concurrently. Without this, messages addressed
                    // to a non-current identity drop on the floor.
                    //
                    // Each inbound message is decrypted at receive
                    // time by the dispatcher; member-roster
                    // announcements apply directly to
                    // `GroupRepository.memberProfiles`, everything
                    // else falls through to the invitations queue.
                    // Cache + retry around the raw relayer reads. Without
                    // this, every relay reconnect replays the full inbox
                    // and each replayed group-state message fired its own
                    // `get_commitment`, storming the relayer into
                    // throttling fresh joins. See `CachingChainStateReader`.
                    let chainStateReader = CachingChainStateReader(
                        inner: SEPContractChainStateReader(
                            relayers: relayerRepository,
                            contracts: contractsRepository,
                            makeContractTransport: contractTransportFactory
                        )
                    )
                    let dispatcher = IncomingMessageDispatcher(
                        envelopeDecrypter: identityRepository,
                        identities: identityRepository,
                        groupRepository: groupRepository,
                        invitationsRepository: incomingInvitations,
                        chainState: chainStateReader,
                        messageRepository: messageRepository,
                        pendingInvites: pendingInvitesStore,
                        groupStateRefresher: groupStateVerifier,
                        receiptSender: ChatReceiptSender(
                            identity: identityRepository,
                            inboxTransport: inboxTransport
                        ),
                        readReceiptsEnabled: { ReadReceiptsPreference.isEnabled }
                    )
                    // Close the loop for the Retry on a snapshot parked
                    // because *this* device couldn't read the chain. The
                    // dispatcher owns verification and holds the
                    // verifier, so the back-reference is installed here
                    // rather than threaded through both initializers.
                    await groupStateVerifier.setReverify { invitation, owner, signer in
                        // Re-fetch the relayer + contract lists first.
                        // The overwhelmingly common reason a joiner
                        // can't read the chain is that neither has
                        // arrived yet — both are fetched from GitHub in
                        // the background at launch, and a device that
                        // was offline for those few seconds has no
                        // endpoint to call and no contract to call it
                        // on. Retrying the read alone would fail the
                        // same way every time.
                        // `refresh`, not `start`: `start` returns as soon
                        // as it has spawned the fetch, so the read below
                        // would race it and fail exactly as before.
                        try? await relayerRepository.refresh()
                        try? await contractsRepository.refresh()
                        await dispatcher.reverify(
                            invitation: invitation,
                            ownerIdentityID: owner,
                            senderEd25519PublicKey: signer
                        )
                    }
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
                    // GC intro keys whose owner identity no longer
                    // exists (identity removed without the cascade
                    // firing, or orphaned by an app delete/reinstall —
                    // the keychain blob outlives the app container).
                    // Each stale entry costs a relay subscription slot
                    // through this pump, forever.
                    // Skip the prune when the identity load fails —
                    // an orphaned key surviving until next launch is
                    // recoverable; pruning against a partial identity
                    // list would wipe live invite-link inboxes. Also
                    // skip on a successful-but-EMPTY load (fresh
                    // install post-quarantine, or bootstrap losing the
                    // race): with zero identities the pump subscribes
                    // nothing anyway, and pruning would permanently
                    // destroy intro keys whose quarantined owners a
                    // recovery flow could still bring back.
                    if let identities = try? await identityRepository.currentIdentities(),
                       !identities.isEmpty {
                        await introKeyStore.pruneOwners(keeping: Set(identities.map(\.id)))
                    }
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
                .task {
                    // DEBUG-only: deliver a `--open-url` deeplink at
                    // launch so a UI test can drive the Join flow
                    // without Safari. No-op in Release.
                    #if DEBUG
                    if pendingCapability == nil,
                       let url = initialDeeplinkURL,
                       let cap = DeeplinkCapture.introCapability(from: url) {
                        pendingCapability = cap
                    }
                    #endif
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
    /// (`app.onym.ios.identity.uitests`) so they never touch the user's
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
            UserDefaults.standard.removeObject(forKey: "app.onym.ios.identity.selectedID")
        }
        let repo = IdentityRepository(keychain: keychain)
        let auth: BiometricAuthenticator = args.contains("--mock-biometric")
            ? AlwaysAcceptAuthenticator()
            : LAContextAuthenticator()
        return (repo, auth)
    }
}
#endif
