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

    /// Whether the blocking consent sheet is up. Driven by the gate;
    /// a `Bool` binding because `fullScreenCover(isPresented:)` wants
    /// one, with the gate as the single source of truth.
    @State private var showConsent = false

    var body: some View {
        // The moderation gate is the enforcement surface (DeviceCheck
        // profile §5): banned and gate-check-required replace the app
        // wholesale; consent covers it; an open case only banners it.
        Group {
            switch dependencies.moderationGateFlow.gate {
            case .banned(let banState):
                BannedView(state: banState)
            case .gateCheckRequired(let reason):
                GateCheckRequiredView(reason: reason) {
                    dependencies.moderationGateFlow.tappedRetry()
                }
            case .checking, .needsConsent, .operational:
                tabs
                    .overlay(alignment: .top) {
                        if case .operational(let openCases) = dependencies.moderationGateFlow.gate,
                           !openCases.isEmpty {
                            OpenCaseBanner(notices: openCases)
                        }
                    }
            }
        }
        .task { dependencies.moderationGateFlow.start() }
        .onChange(of: dependencies.moderationGateFlow.gate) { _, gate in
            showConsent = gate == .needsConsent
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dependencies.moderationGateFlow.appForegrounded()
            }
        }
        .fullScreenCover(isPresented: $showConsent) {
            ModerationConsentView(
                flow: dependencies.makeModerationConsentFlow(.onboarding)
            )
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                NavigationStack {
                    ChatsView(
                        flow: dependencies.makeChatsFlow(),
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
                        makeModerationConsentFlow: dependencies.makeModerationConsentFlow
                    )
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                let chatsFlow = dependencies.makeChatsFlow()
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
                            chatsFlow: dependencies.makeChatsFlow(),
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
                            scrollToMessageID: result.messageID
                        )
                    }
                }
            }
        }
    }
}
