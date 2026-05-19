import SwiftUI

/// SwiftUI host for `ChatThreadViewController`. The chat screen is
/// UIKit (per the design call on #150) but the surrounding app is
/// SwiftUI, so this wrapper:
///
/// 1. Embeds the controller via `UIViewControllerRepresentable`.
/// 2. Hides the SwiftUI nav bar — the controller paints its own.
/// 3. Pipes the controller's back tap through `Environment(\.dismiss)`
///    so the surrounding `NavigationStack` pops cleanly.
/// 4. Pushes `ChatMembersView` when the controller fires its
///    "info tapped" closure, via `navigationDestination(isPresented:)`.
///
/// The group name is computed reactively from `chatsFlow` and pushed
/// into the controller on every render — `updateUIViewController`
/// keeps the title in sync as the group renames without re-creating
/// the controller.
struct ChatThreadView: View {
    let groupID: String
    @Bindable var chatsFlow: ChatsFlow
    @Bindable var identitiesFlow: IdentitiesFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow

    @Environment(\.dismiss) private var dismiss
    @State private var showMembers: Bool = false

    var body: some View {
        ChatThreadControllerBridge(
            groupName: currentGroupName,
            onBack: { dismiss() },
            onShowMembers: { showMembers = true }
        )
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showMembers) {
            ChatMembersView(
                groupID: groupID,
                chatsFlow: chatsFlow,
                identitiesFlow: identitiesFlow,
                makeShareInviteFlow: makeShareInviteFlow
            )
        }
    }

    private var currentGroupName: String {
        chatsFlow.groups.first { $0.id == groupID }?.name ?? "Chat"
    }
}

private struct ChatThreadControllerBridge: UIViewControllerRepresentable {
    let groupName: String
    let onBack: () -> Void
    let onShowMembers: () -> Void

    func makeUIViewController(context: Context) -> ChatThreadViewController {
        let vc = ChatThreadViewController()
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.loadViewIfNeeded()
        vc.update(groupName: groupName)
        return vc
    }

    func updateUIViewController(_ vc: ChatThreadViewController, context: Context) {
        // Closures are refreshed every render — SwiftUI captures the
        // *current* `dismiss` + `showMembers` setters, so the version
        // the controller invokes always reflects the live binding.
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.update(groupName: groupName)
    }
}
