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

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                NavigationStack {
                    ChatsView(
                        flow: dependencies.makeChatsFlow(),
                        identitiesFlow: dependencies.identitiesFlow,
                        makeCreateGroupFlow: dependencies.makeCreateGroupFlow
                    )
                }
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView(
                        makeBackupFlow: dependencies.makeRecoveryPhraseBackupFlow,
                        makeRelayerSettingsFlow: dependencies.makeRelayerSettingsFlow,
                        makeAnchorsPickerFlow: dependencies.makeAnchorsPickerFlow,
                        identitiesFlow: dependencies.identitiesFlow
                    )
                }
            }

            Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack {
                    SearchView()
                }
            }
        }
    }
}
