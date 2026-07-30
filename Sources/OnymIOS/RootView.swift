import SwiftUI

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
    // Held in @State so they survive RootView body re-evaluations. Built
    // inline in `body` before, a fresh ChatsFlow was minted on every
    // re-render; `.task { flow.start() }` keys off the view's identity
    // and does NOT re-fire for the replacement instance, so an unstarted
    // (empty) flow backed the chat list until a tab switch forced `.task`
    // to run again — the "chat list empty until I visit Settings and come
    // back" bug (design doc F5). A view must tolerate body re-evaluation;
    // owning the flows here makes their subscriptions durable.
    @State private var chatsFlow: ChatsFlow
    @State private var searchChatsFlow: ChatsFlow

    @MainActor
    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _chatsFlow = State(initialValue: dependencies.makeChatsFlow())
        _searchChatsFlow = State(initialValue: dependencies.makeChatsFlow())
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                NavigationStack {
                    ChatsView(
                        flow: chatsFlow,
                        identitiesFlow: dependencies.identitiesFlow,
                        connectionStatusFlow: dependencies.connectionStatusFlow,
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
                        setGroupName: dependencies.setGroupName
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
                        onClearAllMessages: { await dependencies.messageRepository.removeAll() }
                    )
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack {
                    SearchView(
                        messageRepository: dependencies.messageRepository,
                        chatsFlow: searchChatsFlow,
                        identitiesFlow: dependencies.identitiesFlow,
                        sendMessageInteractor: dependencies.sendMessageInteractor,
                        chatReceiptSender: dependencies.chatReceiptSender,
                        makeShareInviteFlow: dependencies.makeShareInviteFlow,
                        setGroupAvatar: dependencies.setGroupAvatar,
                        setGroupName: dependencies.setGroupName,
                        imageLoader: dependencies.imageLoader,
                        videoLoader: dependencies.videoLoader,
                        voiceLoader: dependencies.voiceLoader
                    )
                }
            }
        }
    }
}
