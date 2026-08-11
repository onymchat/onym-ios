import SwiftUI
import OnymSearch
import OnymChatsUI
import OnymSettings
import OnymModerationUI

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

    /// The blocking consent sheet, when one is up. Driven by the gate,
    /// which stays the single source of truth: `needsConsent` presents
    /// onboarding, `needsReconsent` presents the same surface with the
    /// reason attached, and anything else dismisses it.
    @State private var consentPresentation: ConsentPresentation?

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
        .task { dependencies.moderationGateFlow.start() }
        .onChange(of: dependencies.moderationGateFlow.gate) { _, gate in
            let next = Self.presentation(for: gate)
            guard next?.id != consentPresentation?.id else { return }
            guard consentPresentation != nil, next != nil else {
                consentPresentation = next
                return
            }
            // One gate replacing another while a cover is already up
            // (terms change, then the authority leaves the directory).
            // `fullScreenCover(item:)` is not dependable about
            // re-presenting on an identity change alone, and the failure
            // is silent — the old reason and old flow stay on screen.
            // Dismissing first makes the swap explicit.
            consentPresentation = nil
            Task { @MainActor in
                // Re-derive rather than replaying the captured value:
                // the gate can move again before this turn runs (the
                // stale mandate resolving, a swap back), and applying a
                // superseded decision would put an undismissable cover
                // back over an app that no longer needs one.
                consentPresentation = Self.presentation(
                    for: dependencies.moderationGateFlow.gate
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dependencies.moderationGateFlow.appForegrounded()
            }
        }
        .fullScreenCover(item: $consentPresentation) { presentation in
            ModerationConsentView(
                flow: dependencies.makeModerationConsentFlow(presentation.mode)
            )
        }
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
                        makeModerationCaseFlow: dependencies.makeModerationCaseFlow
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
