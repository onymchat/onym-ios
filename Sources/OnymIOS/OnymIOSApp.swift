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
import OnymDiscovery
import OnymFoundation
import OnymOnboarding

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
    /// Discovery seat: verified provider catalogs that back the four
    /// known-list fetchers (see `DiscoverySeatAdapters`). Nil under
    /// the UI harness, like the other network fetchers — the legacy
    /// fetchers then run unwrapped.
    private let discoveryRepository: DiscoveryRepository?
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

        // Discovery seat. The repository owns the user's provider
        // sources + the verified catalog aggregate; the seat adapters
        // below wrap the four legacy known-list fetchers with
        // discovery-backed ones that MERGE consented catalog endpoints
        // into the legacy list (and serve legacy alone on any
        // failure): this layer provides the `makeConsentGate`
        // factory the adapters' consent-gate seam takes (declared
        // below), so a discovery endpoint reaches a known list — and
        // first-launch auto-populate — only with an active pinned
        // consent record pinning the exact bytes the catalog entry
        // currently lists. This layer likewise enables the authorities
        // adapter's `discoveryEnabled` seam (this build ships the
        // discovery surface): the catalog directory merges with the
        // legacy one, with LEGACY winning any componentId collision —
        // a catalog entry must never shadow a published authority's
        // apiBaseURL or operator key. Picking stays consent-free; the
        // signed mandate downstream is the consent step. No network
        // fetch under the UI harness — same rule as the Nostr /
        // Blossom fetchers below, so tests stay deterministic +
        // offline (UI-test discovery fakes land with the settings-UI
        // PR).
        // One fetcher instance serves both the repository and the seat
        // catalog below — same URLSession, same size caps; no second
        // session to configure and drift.
        let discoveryFetcher: any DiscoveryFetching
        let discoveryRepository: DiscoveryRepository?
        #if DEBUG
        if args.contains("--ui-testing") && args.contains("--ui-discovery") {
            // `--ui-discovery` (with `--ui-testing`): the discovery
            // surface runs against byte-pinned fixture documents served
            // offline — real signatures, real `DiscoveryTrust` checks,
            // fixture-era `now` so the tests outlive the fixtures'
            // expiry dates. See `UITestDiscoveryFakes.swift`. Without
            // the flag, `--ui-testing` keeps discovery nil exactly as
            // before, so every existing UI test is untouched.
            let fetcher = UITestDiscoveryFetcher()
            discoveryFetcher = fetcher
            discoveryRepository = DiscoveryRepository(
                fetcher: fetcher,
                store: InMemoryDiscoveryStore(),
                now: { UITestDiscoveryFixtures.now }
            )
        } else {
            discoveryFetcher = URLSessionDiscoveryFetcher()
            discoveryRepository = args.contains("--ui-loopback") || args.contains("--ui-testing")
                ? nil
                : DiscoveryRepository(
                    fetcher: discoveryFetcher,
                    store: UserDefaultsDiscoveryStore()
                )
        }
        #else
        discoveryFetcher = URLSessionDiscoveryFetcher()
        discoveryRepository = DiscoveryRepository(
            fetcher: discoveryFetcher,
            store: UserDefaultsDiscoveryStore()
        )
        #endif
        self.discoveryRepository = discoveryRepository
        // Shared seam the four seat adapters fetch catalog entries +
        // destination manifests through. Nil exactly when the
        // repository is nil — `wrapping(_:catalog:)` then returns the
        // legacy fetcher unwrapped.
        let discoveryCatalog = discoveryRepository.map {
            DiscoverySeatCatalog(repository: $0, fetcher: discoveryFetcher)
        }
        // Consent gate for the discovery-backed known-list fetchers:
        // a discovery-derived endpoint may only enter a known list —
        // and thereby the repositories' first-launch auto-populate —
        // when the user holds an active pinned consent whose
        // `manifestHash` equals the exact digest the catalog entry
        // currently lists. Consent is consent to BYTES, not to a
        // componentId: after an operator republishes (new digest, new
        // endpoint, same componentId), the old record must not admit
        // the unreviewed manifest — the pickers render that state as
        // TERMS CHANGED and only a fresh consent re-admits the entry.
        // A factory rather than a bare closure so each fetch pass
        // loads + decodes the consent store ONCE (the check runs per
        // entry) while staying fresh across passes. Declared up here
        // because the fetchers below are constructed before the
        // consent UI wiring; the store is the same one the module
        // consent flow writes to.
        let pinnedConsentStore = UserDefaultsPinnedConsentStore()
        let makeDiscoveryConsentGate: @Sendable () -> DiscoveryConsentCheck = {
            // `try?` is fail-closed: a corrupt consent store gates
            // every discovery-derived endpoint out of the known lists.
            let activeHashes = ((try? pinnedConsentStore.load()) ?? [])
                .reduce(into: [String: String]()) { hashes, record in
                    guard record.isActive else { return }
                    hashes[record.componentId] = record.manifestHash
                }
            return { componentId, manifestDigest in
                activeHashes[componentId] == manifestDigest
            }
        }

        // Onboarding gate — decided ONCE per launch, before the relayer
        // repository exists because its first-launch auto-populate
        // policy depends on the decision. `shouldOnboard` is a pure
        // read: completed flag OR existing-user state (any
        // `hasUserInteracted`, or a moderation mandate) means no
        // onboarding — users who predate the flow are grandfathered,
        // never re-onboarded (see `OnboardingGate`).
        let onboardingStore = UserDefaultsOnboardingStore()
        let shouldOnboard: Bool
        #if DEBUG
        if args.contains("--ui-testing") {
            // `--reset-keychain` starts each UI test from the same
            // first-launch shape — the onboarding flag resets through
            // the store rather than a hardcoded key (OnboardingStore
            // contract).
            if args.contains("--reset-keychain") {
                onboardingStore.resetOnboarding()
            }
            // The UI harness never onboards unless `--ui-onboarding`
            // opts in, so every existing UI test launches exactly as
            // before. Under the opt-in the fakes are a fresh world, so
            // the existing-user probe answers false by construction.
            // `--skip-onboarding` is the explicit veto — AppLauncher
            // passes it by default so a suite's no-onboarding posture
            // is declared in its launch arguments, and it wins over
            // `--ui-onboarding` should both ever appear.
            shouldOnboard = args.contains("--ui-onboarding")
                && !args.contains("--skip-onboarding")
                && OnboardingGate.shouldOnboard(store: onboardingStore, isExistingUser: { false })
        } else {
            // `--skip-onboarding` also works for plain DEBUG runs —
            // a developer convenience for skipping the walk on a
            // fresh simulator without composing UserDefaults.
            shouldOnboard = !args.contains("--skip-onboarding")
                && OnboardingGate.shouldOnboard(
                    store: onboardingStore,
                    isExistingUser: { OnboardingLaunch.isExistingUser() }
                )
        }
        #else
        shouldOnboard = OnboardingGate.shouldOnboard(
            store: onboardingStore,
            isExistingUser: { OnboardingLaunch.isExistingUser() }
        )
        #endif
        // Whether onboarding is AVAILABLE in this build — factories,
        // restart controller, and the Settings row all key off this.
        // Distinct from `shouldOnboard` (the launch-time presentation
        // decision) since Settings → Restart Onboarding can start a
        // walk mid-session on a launch that didn't onboard.
        #if DEBUG
        let onboardingAvailable = args.contains("--ui-testing")
            ? args.contains("--ui-onboarding")
            : true
        #else
        let onboardingAvailable = true
        #endif
        // While an onboarding walk is (or will be) active, a
        // background relayer fetch must not install the whole
        // published list over the notary step's empty configuration —
        // the step IS the choice. The policy re-reads the store per
        // fetch pass, so the very first refresh after `complete()`
        // (kicked by the flow's onCompleted) installs the defaults
        // when the user skipped the step. On steady-state launches the
        // suppressor is the restart marker alone: the completion flag
        // can't serve there, because grandfathered users never carry
        // it and must keep today's auto-populate behavior.
        let relayerAutoPopulatePolicy: @Sendable () -> Bool
        if shouldOnboard {
            relayerAutoPopulatePolicy = {
                onboardingStore.hasCompletedOnboarding()
                    && !onboardingStore.isRestartRequested()
            }
        } else if onboardingAvailable {
            relayerAutoPopulatePolicy = { !onboardingStore.isRestartRequested() }
        } else {
            relayerAutoPopulatePolicy = { true }
        }

        let relayerRepository: RelayerRepository
        let contractsRepository: ContractsRepository
        #if DEBUG
        if args.contains("--ui-testing") {
            relayerRepository = RelayerRepository(
                fetcher: UITestKnownRelayersFetcher(),
                store: UITestRelayerSelectionStore(),
                autoPopulatePolicy: relayerAutoPopulatePolicy
            )
            contractsRepository = ContractsRepository(
                fetcher: UITestContractsManifestFetcher(),
                store: UITestAnchorSelectionStore()
            )
        } else {
            relayerRepository = RelayerRepository(
                fetcher: DiscoveryBackedKnownRelayersFetcher.wrapping(
                    GitHubReleasesKnownRelayersFetcher(),
                    catalog: discoveryCatalog,
                    makeConsentGate: makeDiscoveryConsentGate
                ),
                store: UserDefaultsRelayerSelectionStore(),
                autoPopulatePolicy: relayerAutoPopulatePolicy
            )
            contractsRepository = ContractsRepository(
                fetcher: GitHubReleasesContractsManifestFetcher(),
                store: UserDefaultsAnchorSelectionStore()
            )
        }
        #else
        relayerRepository = RelayerRepository(
            fetcher: DiscoveryBackedKnownRelayersFetcher.wrapping(
                GitHubReleasesKnownRelayersFetcher(),
                catalog: discoveryCatalog,
                makeConsentGate: makeDiscoveryConsentGate
            ),
            store: UserDefaultsRelayerSelectionStore(),
            autoPopulatePolicy: relayerAutoPopulatePolicy
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
                authoritiesFetcher: DiscoveryBackedKnownAuthoritiesFetcher.wrapping(
                    GitHubReleasesKnownAuthoritiesFetcher(),
                    catalog: discoveryCatalog,
                    // This build layer ships the discovery surface —
                    // enable the (legacy-wins) directory merge.
                    discoveryEnabled: { true }
                ),
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
            authoritiesFetcher: DiscoveryBackedKnownAuthoritiesFetcher.wrapping(
                GitHubReleasesKnownAuthoritiesFetcher(),
                catalog: discoveryCatalog,
                // This build layer ships the discovery surface —
                // enable the (legacy-wins) directory merge.
                discoveryEnabled: { true }
            ),
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
        // first launch. Uploads/downloads target the first configured
        // server; the client re-reads the repository per operation, so
        // changes in Settings (or an onboarding pick) apply to the very
        // next upload/download — no relaunch needed.
        let blossomStore = UserDefaultsBlossomServersSelectionStore()
        // No network fetch under the UI harness — the hardcoded seed
        // stays the default so tests are deterministic + offline.
        let blossomFetcher: (any KnownBlossomServersFetcher)?
        #if DEBUG
        blossomFetcher = args.contains("--ui-loopback") || args.contains("--ui-testing")
            ? nil
            : DiscoveryBackedKnownBlossomServersFetcher.wrapping(
                GitHubReleasesKnownBlossomServersFetcher(),
                catalog: discoveryCatalog,
                makeConsentGate: makeDiscoveryConsentGate
            )
        #else
        blossomFetcher = DiscoveryBackedKnownBlossomServersFetcher.wrapping(
            GitHubReleasesKnownBlossomServersFetcher(),
            catalog: discoveryCatalog,
            makeConsentGate: makeDiscoveryConsentGate
        )
        #endif
        let blossomServersRepository = BlossomServersRepository(
            store: blossomStore,
            fetcher: blossomFetcher
        )
        self.blossomServersRepository = blossomServersRepository
        // Live base-URL resolution: the first configured server *right
        // now*, falling back to the app default when the list is empty.
        // Shared by the client below and the `server` stamp on outgoing
        // attachments, so both always agree.
        // Plain first endpoint: the user's OWN configuration is
        // trusted as typed — the scheme is not second-guessed here
        // (`BlossomRelaySettingsFlow.validate` deliberately accepts
        // http for local dev / loopback), and Settings' ACTIVE badge
        // is first-row-based, so badge and target agree by
        // construction. https-only enforcement belongs to the
        // PEER-influenced paths (download stamps via
        // BlossomServerStampPolicy, catalog applies via
        // requiredEndpointURL) — never to hand-typed endpoints.
        let resolveBlossomBaseURL: @Sendable () async -> URL = {
            await blossomServersRepository.currentEndpoints().first?.url
                ?? URLSessionBlossomClient.defaultBaseURL
        }

        // Blossom client + image loader for image messages. Swapped for
        // an in-memory store under `--ui-loopback` so image send/receive
        // round-trips with no network; one shared instance so the loader
        // can read back what the sender uploaded. The production client
        // resolves its base URL per operation via the repository, so a
        // server change takes effect without a relaunch.
        let makeLiveBlossomClient: () -> any BlossomClient = {
            DynamicBaseURLBlossomClient(
                resolveBaseURL: resolveBlossomBaseURL,
                makeClient: {
                    URLSessionBlossomClient(
                        baseURL: $0,
                        signerProvider: OnymNostrSignerProvider()
                    )
                }
            )
        }
        let blossomClient: any BlossomClient
        #if DEBUG
        if args.contains("--ui-loopback") {
            blossomClient = UITestBlossomClient()
        } else {
            blossomClient = makeLiveBlossomClient()
        }
        #else
        blossomClient = makeLiveBlossomClient()
        #endif
        // The loaders may honor an attachment's `server` stamp only
        // within this set — the user's own configured servers — never
        // a peer-chosen host (see BlossomServerStampPolicy).
        let allowedStampServers: @Sendable () async -> [URL] = {
            await blossomServersRepository.currentEndpoints().map(\.url)
        }
        let imageLoader = ChatImageLoader(
            blossomClient: blossomClient,
            allowedStampServers: allowedStampServers
        )
        self.imageLoader = imageLoader
        let videoLoader = ChatVideoLoader(
            blossomClient: blossomClient,
            allowedStampServers: allowedStampServers
        )
        self.videoLoader = videoLoader
        let voiceLoader = ChatVoiceLoader(
            blossomClient: blossomClient,
            allowedStampServers: allowedStampServers
        )
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
            ? nil
            : DiscoveryBackedKnownNostrRelaysFetcher.wrapping(
                GitHubReleasesKnownNostrRelaysFetcher(),
                catalog: discoveryCatalog,
                makeConsentGate: makeDiscoveryConsentGate
            )
        #else
        nostrFetcher = DiscoveryBackedKnownNostrRelaysFetcher.wrapping(
            GitHubReleasesKnownNostrRelaysFetcher(),
            catalog: discoveryCatalog,
            makeConsentGate: makeDiscoveryConsentGate
        )
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

        // Discovery-driven module consent (Settings UI). The stores are
        // the app-wide consent + selection provenance; the entitlement
        // stub grants free offers only (StoreKit slots in behind the
        // same seam later). Each picker pre-binds its seat type and the
        // seat-specific `apply` closure that writes a consented
        // manifest's endpoint into the legacy configuration — the
        // operational source of truth stays where it always was. All
        // nil when discovery is nil (UI-test harness), which leaves
        // every settings screen exactly as it was.
        // (`pinnedConsentStore` itself is declared next to the seat
        // adapters above — the known-list consent gate reads it.)
        let seatSelectionStore = UserDefaultsSeatSelectionStore()
        /// Live per-seat catalog entries for the pickers' "From
        /// catalog" sections: the repository's snapshot stream mapped
        /// to one seat type, yielding the current aggregate on
        /// subscribe and again after every refresh — so an open picker
        /// populates when the boot-time refresh lands.
        let makeSeatEntriesStream = discoveryRepository.map { repo in
            { @Sendable (seatType: String) -> AsyncStream<[AttributedCatalogEntry]> in
                AsyncStream { continuation in
                    let task = Task {
                        for await state in repo.snapshots {
                            continuation.yield(
                                state.aggregate.filter { $0.entry.seatType == seatType }
                            )
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }
        /// Entitlements for the consent surface, resolved against the
        /// manifest currently under review — the consent store alone
        /// can't answer on FIRST consent (no record exists yet, so
        /// even free offers would gate as not-entitled); the store is
        /// only the fallback for offers the reviewed manifest doesn't
        /// carry. StoreKit slots in behind the same seam later.
        let makeEntitlements: @Sendable (SignedServiceManifest) -> any EntitlementProviding = { manifest in
            FreeTierEntitlementProvider(reviewing: manifest, consentStore: pinnedConsentStore)
        }

        /// Manifest `name` when published and non-empty, else the
        /// component id minus its prefix — same rule as the adapters.
        func discoveryDisplayName(_ fields: SeatManifestFields, componentId: String) -> String {
            if let name = fields.name, !name.isEmpty { return name }
            return ModuleConsentFlow.shortComponentId(componentId)
        }

        let relayerCatalogPicker = discoveryCatalog.map { catalog in
            DiscoveryModulePicker(
                entries: { await catalog.entries(DiscoveryBackedKnownRelayersFetcher.seatType) },
                activeConsent: { try? pinnedConsentStore.activeRecord(componentId: $0) },
                entriesStream: makeSeatEntriesStream.map { make in
                    { make(DiscoveryBackedKnownRelayersFetcher.seatType) }
                },
                makeConsentFlow: { entry in
                    ModuleConsentFlow(
                        entry: entry,
                        fetchManifestBytes: catalog.fetchManifestBytes,
                        consentStore: pinnedConsentStore,
                        selectionStore: seatSelectionStore,
                        makeEntitlements: makeEntitlements,
                        apply: { manifest in
                            let fields = SeatManifestFields(rawBytes: manifest.rawBytes)
                            // Throws `ModuleApplyError.noUsableEndpoint`
                            // when the manifest has no https endpoint —
                            // the flow surfaces it instead of showing
                            // "Service added" over a no-op.
                            let url = try ModuleConsentAcceptance.requiredEndpointURL(
                                in: fields.endpointURIs,
                                scheme: "https"
                            )
                            // `addEndpoint` flips the configuration's
                            // `hasUserInteracted` to true, so a refresh
                            // never auto-populates over this choice.
                            await relayerRepository.addEndpoint(RelayerEndpoint(
                                name: discoveryDisplayName(fields, componentId: manifest.componentId),
                                url: url,
                                networks: fields.networks
                                    ?? DiscoveryBackedKnownRelayersFetcher.defaultNetworks
                            ))
                        }
                    )
                }
            )
        }

        let nostrCatalogPicker = discoveryCatalog.map { catalog in
            DiscoveryModulePicker(
                entries: { await catalog.entries(DiscoveryBackedKnownNostrRelaysFetcher.seatType) },
                activeConsent: { try? pinnedConsentStore.activeRecord(componentId: $0) },
                entriesStream: makeSeatEntriesStream.map { make in
                    { make(DiscoveryBackedKnownNostrRelaysFetcher.seatType) }
                },
                makeConsentFlow: { entry in
                    ModuleConsentFlow(
                        entry: entry,
                        fetchManifestBytes: catalog.fetchManifestBytes,
                        consentStore: pinnedConsentStore,
                        selectionStore: seatSelectionStore,
                        makeEntitlements: makeEntitlements,
                        apply: { manifest in
                            let fields = SeatManifestFields(rawBytes: manifest.rawBytes)
                            // Throws `ModuleApplyError.noUsableEndpoint`
                            // when the manifest has no wss endpoint —
                            // surfaced by the flow, never a silent no-op.
                            let url = try ModuleConsentAcceptance.requiredEndpointURL(
                                in: fields.endpointURIs,
                                scheme: "wss"
                            )
                            // A consent-picked relay is the user's own
                            // choice, not a published default — no
                            // "Default" badge, and `addEndpoint` marks
                            // the configuration user-interacted.
                            await nostrRelaysRepository.addEndpoint(NostrRelayEndpoint(
                                name: discoveryDisplayName(fields, componentId: manifest.componentId),
                                url: url,
                                isDefault: false
                            ))
                        }
                    )
                }
            )
        }

        let blossomCatalogPicker = discoveryCatalog.map { catalog in
            DiscoveryModulePicker(
                entries: { await catalog.entries(DiscoveryBackedKnownBlossomServersFetcher.seatType) },
                activeConsent: { try? pinnedConsentStore.activeRecord(componentId: $0) },
                entriesStream: makeSeatEntriesStream.map { make in
                    { make(DiscoveryBackedKnownBlossomServersFetcher.seatType) }
                },
                makeConsentFlow: { entry in
                    ModuleConsentFlow(
                        entry: entry,
                        fetchManifestBytes: catalog.fetchManifestBytes,
                        consentStore: pinnedConsentStore,
                        selectionStore: seatSelectionStore,
                        makeEntitlements: makeEntitlements,
                        apply: { manifest in
                            // Extracted (BlossomCatalogConsent) so the
                            // endpoint extraction + make-active ordering
                            // is unit-tested: the pick becomes the FIRST
                            // endpoint — the upload/download target —
                            // not an inert append behind the seed.
                            try await BlossomCatalogConsent.apply(
                                manifest: manifest,
                                to: blossomServersRepository
                            )
                        }
                    )
                }
            )
        }

        // Settings-flow factories, declared once because the
        // onboarding steps reuse them VERBATIM: a step surface and its
        // Settings screen are the same flow over the same repository +
        // catalog picker, so a choice consents and applies identically
        // in both places.
        let makeRelayerSettingsFlow: @MainActor () -> RelayerSettingsFlow = { @MainActor in
            RelayerSettingsFlow(repository: relayerRepository, discovery: relayerCatalogPicker)
        }
        let makeNostrRelaySettingsFlow: @MainActor () -> NostrRelaySettingsFlow = { @MainActor in
            NostrRelaySettingsFlow(repository: nostrRelaysRepository, discovery: nostrCatalogPicker)
        }
        let makeBlossomRelaySettingsFlow: @MainActor () -> BlossomRelaySettingsFlow = { @MainActor in
            BlossomRelaySettingsFlow(repository: blossomServersRepository, discovery: blossomCatalogPicker)
        }
        let makeModerationConsentFlow: @MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow = { @MainActor mode in
            ModerationConsentFlow(
                mode: mode,
                repository: moderationRepository,
                onConsented: { moderationGateFlow.consentCompleted() }
            )
        }
        let makeDiscoverySettingsFlow = discoveryRepository.map { repo in
            { @MainActor in DiscoverySettingsFlow(repository: repo) }
        }

        // Onboarding factories. Built whenever onboarding is AVAILABLE
        // (not only when this launch presents it): Settings → Restart
        // Onboarding needs them on steady-state launches too. All nil
        // only under the UI-test harness without `--ui-onboarding`.
        let makeOnboardingFlow: (@MainActor () -> OnboardingFlow)?
        let makeOnboardingStepContent: (@MainActor (OnboardingFlow, OnboardingStep) -> AnyView?)?
        let onboardingRestartController: OnboardingRestartController?
        if onboardingAvailable {
            onboardingRestartController = OnboardingRestartController(store: onboardingStore)
            makeOnboardingFlow = { @MainActor in
                OnboardingFlow(
                    store: onboardingStore,
                    moderationDirectoryNonEmpty: {
                        // The flow fails closed until this answers; a
                        // failed refresh falls back to whatever the
                        // repository already holds (cached directory
                        // or empty).
                        try? await moderationRepository.refresh()
                        return await !moderationRepository.currentState().authorities.isEmpty
                    },
                    onCompleted: { @MainActor in
                        // The moderation step signed through the same
                        // repository the gate watches; poke the gate so
                        // it re-checks immediately instead of
                        // re-prompting — same call the standalone
                        // consent cover makes.
                        moderationGateFlow.consentCompleted()
                        // Completion flips the relayer auto-populate
                        // policy back on — install the published notary
                        // defaults now if the user skipped that step.
                        Task { try? await relayerRepository.refresh() }
                    }
                )
            }
            let builder = OnboardingStepContentBuilder(
                makeDiscoveryFlow: makeDiscoverySettingsFlow,
                makeNostrFlow: makeNostrRelaySettingsFlow,
                nostrPicker: nostrCatalogPicker,
                makeBlossomFlow: makeBlossomRelaySettingsFlow,
                blossomPicker: blossomCatalogPicker,
                makeRelayerFlow: makeRelayerSettingsFlow,
                relayerPicker: relayerCatalogPicker,
                makeModerationConsentFlow: makeModerationConsentFlow,
                // The recovery step runs the same backup walk Settings
                // offers — same biometric gate, same verify quiz.
                makeBackupFlow: { @MainActor in
                    RecoveryPhraseBackupFlow(
                        repository: repository,
                        authenticator: authenticator
                    )
                },
                // Bootstrap is idempotent: this awaits the same call
                // the WindowGroup task fires, so the identity step's
                // checklist reflects the real outcome instead of
                // asserting one.
                identityReady: { @MainActor in
                    (try? await repository.bootstrap()) != nil
                },
                loadSummary: { @MainActor in
                    // The Done step's summary is read from the
                    // repositories, not the walk's outcomes — what the
                    // app will actually use is the checkable claim.
                    var rows: [OnboardingSummaryRow] = []
                    if let discoveryRepository {
                        let state = await discoveryRepository.currentState()
                        if let source = state.sources.first {
                            rows.append(OnboardingSummaryRow(
                                id: "discovery",
                                title: String(localized: "Service Directory"),
                                value: source.source.userLabel,
                                detail: source.source.operatorKeyFingerprint
                            ))
                        }
                    }
                    let nostr = await nostrRelaysRepository.currentEndpoints().first
                    rows.append(OnboardingSummaryRow(
                        id: "messageTransport",
                        title: String(localized: "Message Transport"),
                        value: nostr?.name ?? String(localized: "None configured"),
                        detail: nostr?.url.absoluteString
                    ))
                    let blossom = await blossomServersRepository.currentEndpoints().first
                    rows.append(OnboardingSummaryRow(
                        id: "blobTransport",
                        title: String(localized: "File Storage"),
                        value: blossom?.name ?? String(localized: "None configured"),
                        detail: blossom?.url.absoluteString
                    ))
                    let relayer = await relayerRepository.currentState().configuration.endpoints.first
                    rows.append(OnboardingSummaryRow(
                        id: "notary",
                        title: String(localized: "Notary"),
                        value: relayer?.name ?? String(localized: "Published defaults"),
                        detail: relayer?.url.absoluteString
                    ))
                    let mandate = await moderationRepository.currentState().activeMandate
                    rows.append(OnboardingSummaryRow(
                        id: "moderation",
                        title: String(localized: "Moderation"),
                        value: mandate?.authorityName ?? String(localized: "None"),
                        detail: mandate?.mandate.manifestHash
                    ))
                    return rows
                }
            )
            makeOnboardingStepContent = { @MainActor flow, step in
                builder.content(for: step, flow: flow)
            }
        } else {
            makeOnboardingFlow = nil
            makeOnboardingStepContent = nil
            onboardingRestartController = nil
        }

        self.dependencies = AppDependencies(
            makeRecoveryPhraseBackupFlow: { @MainActor in
                RecoveryPhraseBackupFlow(
                    repository: repository,
                    authenticator: authenticator
                )
            },
            makeRelayerSettingsFlow: makeRelayerSettingsFlow,
            makeNostrRelaySettingsFlow: makeNostrRelaySettingsFlow,
            makeBlossomRelaySettingsFlow: makeBlossomRelaySettingsFlow,
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
                blossomServerURL: { await resolveBlossomBaseURL().absoluteString },
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
            makeModerationConsentFlow: makeModerationConsentFlow,
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
            },
            makeDiscoverySettingsFlow: makeDiscoverySettingsFlow,
            makeOnboardingFlow: makeOnboardingFlow,
            presentOnboardingAtLaunch: shouldOnboard,
            onboardingRestart: onboardingRestartController,
            makeOnboardingStepContent: makeOnboardingStepContent
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
                    // Discovery FIRST: seed the default source (first
                    // run), rebuild the offline aggregate from retained
                    // snapshots, refresh enabled sources in the
                    // background. Nil under the UI harness. Ordering
                    // matters: `start()` rebuilds the retained aggregate
                    // synchronously (inside the actor call) before it
                    // spawns the network refresh, and the repositories
                    // started below read the discovery-backed known-list
                    // fetchers on THEIR start — so this must run first or
                    // a cold boot's adapter reads see an empty aggregate
                    // and serve legacy-only lists.
                    // Known limitation: entries fetched by the background
                    // refresh (including a very first launch, which has
                    // no retained snapshots yet) are not re-pushed into
                    // the repositories this launch — they surface on the
                    // next launch's adapter reads (or a manual refresh in
                    // Settings). Wiring the repositories to the
                    // repository's snapshot stream is the clean seam if
                    // this ever needs to be live.
                    await discoveryRepository?.start()
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
