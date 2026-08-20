import SwiftUI
import OnymSearch
import OnymChatsUI
import OnymBackupUI
import OnymSettings
import OnymModerationUI
import OnymDiscovery
import OnymDesign
import OnymOnboarding

/// App shell — `TabView` with the iOS 18+ `Tab(_, systemImage:, value:)`
/// syntax. The `.search` role places its tab in the system's bottom-right
/// "search" slot (separate from the regular tab strip), matching the
/// stellar-mls / Apple-default Liquid Glass shape.
///
/// Three tabs:
///   - `.chats`    — list of groups the user has created. Default tab on launch.
///                   Empty state hosts the only entry point to Create Group.
///   - `.settings` — recovery-phrase backup, relayer config, anchors picker.
///   - `.search`   — placeholder occupying the system search slot; real
///                   search lands in a future chunk.
struct RootView: View {
    private enum RootTab: Hashable {
        case chats
        case settings
        case search
    }

    let dependencies: AppDependencies

    @State private var selectedTab: RootTab = .chats
    @Environment(\.scenePhase) private var scenePhase

    /// The first-launch onboarding walk, when THIS launch should
    /// onboard (`AppDependencies.makeOnboardingFlow` non-nil — the
    /// gate + grandfathering + UI-test veto were already decided in
    /// `OnymIOSApp.init`). Presented as a full-screen cover over the
    /// tab bar; set back to nil on `complete()`, which dismisses it.
    /// Never re-presented within the session — the flow deliberately
    /// restarts only on a relaunch that still has no completion flag.
    @State private var onboardingFlow: OnboardingFlow?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _onboardingFlow = State(
            initialValue: dependencies.presentOnboardingAtLaunch
                ? dependencies.makeOnboardingFlow?()
                : nil
        )
    }

    /// The blocking consent sheet, when one is up. Driven by the gate,
    /// which stays the single source of truth: `needsConsent` presents
    /// onboarding, `needsReconsent` presents the same surface with the
    /// reason attached, and anything else dismisses it.
    @State private var consentPresentation: ConsentPresentation?
    /// Resolved once at appear, because building it reads a pinned
    /// consent record and derives a seat key — neither of which belongs
    /// in a view body that re-runs on every redraw. `nil` means no
    /// backup operator is consented to, and the Settings section hides.
    @State private var deviceBackupView: DeviceBackupSettingsView?
    /// Guards against two resolutions overlapping — building one reads a
    /// consent record and derives a seat key, and the later of two
    /// in-flight resolutions could otherwise land first.
    @State private var resolvingDeviceBackup = false
    /// Which operator the current backup view was built for.
    ///
    /// Re-resolving unconditionally on every visit to Settings rebuilt
    /// the flow underneath a running backup, discarding its state
    /// mid-upload. The view is only replaced when the consented operator
    /// actually changed.
    @State private var deviceBackupComponentId: String?
    /// A resolution asked for while one was in flight.
    @State private var deviceBackupResolutionPending = false

    /// `fullScreenCover(item:)` needs identity, and the two consent
    /// gates the root can host are exactly "no mandate yet" and "the
    /// mandate is stale, for this reason" — switching is a Settings
    /// task with its own cover and is deliberately not expressible
    /// here. Changing between them rebuilds the flow rather than
    /// reusing it.
    private struct ConsentPresentation: Identifiable, Equatable {
        /// `nil` when there is no mandate at all.
        let reason: ReconsentReason?

        var mode: ModerationConsentFlow.Mode {
            reason.map { .reconsent($0) } ?? .onboarding
        }

        var id: String {
            switch reason {
            case nil: return "onboarding"
            case .termsChanged: return "reconsent.termsChanged"
            case .authorityDelisted: return "reconsent.authorityDelisted"
            }
        }
    }

    var body: some View {
        // The moderation gate is the enforcement surface (DeviceCheck
        // profile §5): banned and gate-check-required replace the app
        // wholesale; consent covers it; an open case only banners it.
        Group {
            switch dependencies.moderationGateFlow.gate {
            case .banned(let banState):
                BannedView(
                    state: banState,
                    makeCaseFlow: dependencies.makeModerationBanCaseFlow
                )
            case .gateCheckRequired(let reason):
                GateCheckRequiredView(
                    reason: reason,
                    onRetry: { await dependencies.moderationGateFlow.tappedRetry() },
                    lookupRecoveryCaseIDs: {
                        await dependencies.lookupModerationRecoveryCaseIDs()
                    },
                    makeRecoveryCaseFlow: { caseId in
                        await dependencies.makeModerationRecoveryCaseFlow(caseId)
                    },
                    makeDeviceRecoveryFlow: dependencies.makeDeviceRecoveryFlow
                )
            case .checking, .needsConsent, .needsReconsent, .operational:
                tabs
            }
        }
        .task {
            dependencies.moderationGateFlow.start()
            // The gate can already be decided by the time this view
            // appears, and `onChange` alone would never present for a
            // value that never changes.
            consentPresentation = presentationUnlessOnboarding(
                for: dependencies.moderationGateFlow.gate
            )
            await resolveDeviceBackupView()
        }
        .onChange(of: selectedTab) { _, tab in
            // Re-resolved when Settings is opened, not only at launch.
            // Consenting to a backup operator mid-session otherwise left
            // the section missing until the next launch, which reads as
            // the consent not having worked.
            guard tab == .settings else { return }
            Task { await resolveDeviceBackupView() }
        }
        .onChange(of: consentPresentation) { _, presentation in
            // Consent can also be given *while already on* Settings, in
            // which case the tab never changes. Re-resolve when a consent
            // sheet closes.
            guard presentation == nil else { return }
            Task { await resolveDeviceBackupView() }
        }
        .onChange(of: dependencies.moderationGateFlow.gate) { _, gate in
            consentPresentation = presentationUnlessOnboarding(for: gate)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dependencies.moderationGateFlow.appForegrounded()
            }
        }
        // Settings → Restart Onboarding: present a fresh walk
        // mid-session. The persisted restart marker (written before
        // this signal fires) already re-armed the auto-populate
        // suppression and makes a mid-walk kill resume on the next
        // launch through the normal gate. Identity, chats, messages,
        // and every current selection are untouched — the step
        // surfaces render the applied configuration and change
        // nothing until the user does.
        .onChange(of: dependencies.onboardingRestart?.pendingRestart ?? false) { _, pending in
            guard pending, let restart = dependencies.onboardingRestart else { return }
            restart.consumeRestart()
            guard onboardingFlow == nil, let make = dependencies.makeOnboardingFlow else { return }
            // The onboarding cover replaces any moderation consent
            // cover for the duration of the walk — its moderation
            // step is the same surface (same suppression as at
            // launch; the gate is re-read on completion).
            consentPresentation = nil
            onboardingFlow = make()
        }
        .fullScreenCover(item: $consentPresentation) { presentation in
            // `.id` rather than a dismiss-and-re-present dance: one gate
            // can replace another while the cover is up (terms change,
            // then the authority leaves the directory), and
            // `fullScreenCover(item:)` is not dependable about rebuilding
            // on an identity change alone. Taking the cover down and
            // putting it back lands inside the dismiss animation, where
            // the likely outcome is no cover at all — an ungated app,
            // strictly worse than a stale reason. This rebuilds the view
            // and its flow in place instead.
            ModerationConsentView(
                flow: dependencies.makeModerationConsentFlow(presentation.mode)
            )
            .id(presentation.id)
        }
        // First-launch onboarding, over everything (the moderation
        // gate's own cover stays suppressed while this is up — the
        // walk's moderation step is the consent surface). A
        // full-screen cover has no interactive dismissal, but the
        // modifier documents intent and guards a future switch to
        // `.sheet`: the only exits are `complete()` on Done and the
        // per-step Skips.
        .fullScreenCover(
            isPresented: Binding(
                get: { onboardingFlow != nil },
                set: { if !$0 { onboardingFlow = nil } }
            )
        ) {
            if let flow = onboardingFlow {
                OnboardingView(
                    flow: flow,
                    stepContent: dependencies.makeOnboardingStepContent.map { make in
                        { step in make(flow, step) }
                    },
                    stepIndicator: { index, count in
                        AnyView(SettingsStepIndicator(step: index, count: count))
                    }
                )
                .interactiveDismissDisabled(true)
                .onChange(of: flow.isCompleted) { _, completed in
                    guard completed else { return }
                    // Dismiss, then hand control back to the
                    // moderation gate: if its answer still demands a
                    // cover (it shouldn't after the walk's consent,
                    // but the gate stays the single source of truth),
                    // it goes up now instead of never.
                    onboardingFlow = nil
                    consentPresentation = Self.presentation(
                        for: dependencies.moderationGateFlow.gate
                    )
                }
            }
        }
    }

    /// The moderation gate's cover is suppressed while onboarding is
    /// up: the walk's moderation step embeds the same consent surface,
    /// so presenting both would stack two identical obligations. The
    /// gate itself keeps running — its answer is re-read the moment
    /// onboarding completes.
    /// Builds the backup screen, or leaves it absent.
    ///
    /// Absent is an ordinary answer: no consented operator, or an
    /// identity with no recovery phrase to derive a key from. Both mean
    /// the Settings section hides rather than offering something that
    /// cannot produce an openable snapshot.
    private func resolveDeviceBackupView() async {
        guard let makeDeviceBackupView = dependencies.makeDeviceBackupView else { return }
        guard !resolvingDeviceBackup else {
            // Queued, not dropped. A request that arrives mid-resolution
            // is usually the one that matters — the consent that just
            // landed — and discarding it leaves the section describing
            // the operator from before.
            deviceBackupResolutionPending = true
            return
        }

        resolvingDeviceBackup = true
        defer { resolvingDeviceBackup = false }

        repeat {
            deviceBackupResolutionPending = false
            // Nothing to do when the operator has not changed. Rebuilding
            // here would hand Settings a fresh flow and throw away a
            // backup that is running.
            let componentId = dependencies.consentedBackupComponentId?()
            if deviceBackupView == nil || componentId != deviceBackupComponentId {
                deviceBackupView = await makeDeviceBackupView()
                deviceBackupComponentId = componentId
            }
        } while deviceBackupResolutionPending
    }

    private func presentationUnlessOnboarding(
        for gate: ModerationGateFlow.RootGate
    ) -> ConsentPresentation? {
        guard onboardingFlow == nil else { return nil }
        return Self.presentation(for: gate)
    }

    /// Both consent gates present the same surface; only the gate
    /// decides which one, so a mandate signed (or a terms check coming
    /// back current) takes the cover down on its own.
    private static func presentation(
        for gate: ModerationGateFlow.RootGate
    ) -> ConsentPresentation? {
        switch gate {
        case .needsConsent:
            return ConsentPresentation(reason: nil)
        case .needsReconsent(let reason):
            return ConsentPresentation(reason: reason)
        case .checking, .banned, .gateCheckRequired, .operational:
            return nil
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                NavigationStack {
                    ChatsView(
                        flow: dependencies.chatsFlow,
                        identitiesFlow: dependencies.identitiesFlow,
                        approveRequestsFlow: dependencies.approveRequestsFlow,
                        pendingInvitesFlow: dependencies.pendingInvitesFlow,
                        messageRepository: dependencies.messageRepository,
                        imageLoader: dependencies.imageLoader,
                        videoLoader: dependencies.videoLoader,
                        voiceLoader: dependencies.voiceLoader,
                        sendMessageInteractor: dependencies.sendMessageInteractor,
                        chatReceiptSender: dependencies.chatReceiptSender,
                        makeCreateGroupFlow: dependencies.makeCreateGroupFlow,
                        makeShareInviteFlow: dependencies.makeShareInviteFlow,
                        makeJoinFlow: dependencies.makeJoinFlow,
                        setGroupAvatar: dependencies.setGroupAvatar,
                        setGroupName: dependencies.setGroupName,
                        makeModerationReportView: dependencies.makeModerationReportView
                    )
                    .chatThreadBottomAccessory {
                        moderationCaseBanner
                    }
                }
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView(
                        makeBackupFlow: dependencies.makeRecoveryPhraseBackupFlow,
                        makeRelayerSettingsFlow: dependencies.makeRelayerSettingsFlow,
                        makeNostrRelaySettingsFlow: dependencies.makeNostrRelaySettingsFlow,
                        makeBlossomRelaySettingsFlow: dependencies.makeBlossomRelaySettingsFlow,
                        makeAnchorsPickerFlow: dependencies.makeAnchorsPickerFlow,
                        identitiesFlow: dependencies.identitiesFlow,
                        onClearAllMessages: { await dependencies.messageRepository.removeAll() },
                        makeModerationSettingsFlow: dependencies.makeModerationSettingsFlow,
                        makeModerationConsentFlow: dependencies.makeModerationConsentFlow,
                        makeModerationCaseFlow: dependencies.makeModerationCaseFlow,
                        makeDiscoverySettingsFlow: dependencies.makeDiscoverySettingsFlow,
                        onRestartOnboarding: dependencies.onboardingRestart.map { restart in
                            { restart.requestRestart() }
                        },
                        makeDeviceBackupView: deviceBackupView.map { view in { view } }
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    moderationCaseBanner
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                let chatsFlow = dependencies.chatsFlow
                NavigationStack {
                    SearchView(
                        messageRepository: dependencies.messageRepository,
                        identitiesFlow: dependencies.identitiesFlow,
                        groupNameForID: { groupID in
                            chatsFlow.groups.first(where: { $0.id == groupID })?.name
                        },
                        startChats: { chatsFlow.start() }
                    )
                    .navigationDestination(for: MessageSearchResult.self) { result in
                        ChatThreadView(
                            groupID: result.groupID,
                            chatsFlow: dependencies.chatsFlow,
                            identitiesFlow: dependencies.identitiesFlow,
                            messageRepository: dependencies.messageRepository,
                            sendMessageInteractor: dependencies.sendMessageInteractor,
                            chatReceiptSender: dependencies.chatReceiptSender,
                            makeShareInviteFlow: dependencies.makeShareInviteFlow,
                            setGroupAvatar: dependencies.setGroupAvatar,
                            setGroupName: dependencies.setGroupName,
                            imageLoader: dependencies.imageLoader,
                            videoLoader: dependencies.videoLoader,
                            voiceLoader: dependencies.voiceLoader,
                            makeModerationReportView: dependencies.makeModerationReportView,
                            approveRequestsFlow: dependencies.approveRequestsFlow,
                            scrollToMessageID: result.messageID
                        )
                    }
                    .chatThreadBottomAccessory {
                        moderationCaseBanner
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var moderationCaseBanner: some View {
        if case .operational(let openCases) = dependencies.moderationGateFlow.gate,
           !openCases.isEmpty {
            OpenCaseBanner(
                notices: openCases,
                makeCaseFlow: dependencies.makeModerationCaseFlow
            )
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }
}
