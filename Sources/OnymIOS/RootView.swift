import SwiftUI

/// App shell — `TabView` with the iOS 18+ `Tab(_, systemImage:, value:)`
/// syntax. The `.search` role places its tab in the system's bottom-right
/// "search" slot (separate from the regular tab strip), matching the
/// stellar-mls / Apple-default Liquid Glass shape.
///
/// Currently two tabs:
///   - `.settings` — entry point for the recovery-phrase backup flow
///   - `.search` — placeholder so the system search slot is occupied;
///                 real search lands in a future chunk
struct RootView: View {
    private enum RootTab: Hashable {
        case settings
        case search
    }

    let dependencies: AppDependencies

    @State private var selectedTab: RootTab = .settings

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView(
                        makeBackupFlow: dependencies.makeRecoveryPhraseBackupFlow,
                        makeRelayerPickerFlow: dependencies.makeRelayerPickerFlow,
                        makeAnchorsPickerFlow: dependencies.makeAnchorsPickerFlow
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
