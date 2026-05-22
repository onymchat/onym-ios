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
    let messageRepository: MessageRepository
    let sendMessageInteractor: SendMessageInteractor
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow

    @Environment(\.dismiss) private var dismiss
    @State private var showMembers: Bool = false
    /// Live snapshot of the group's messages, sorted ascending by
    /// `sentAt`. SwiftUI re-renders on every push so the bridge
    /// hands the controller fresh data via `updateUIViewController`.
    @State private var messages: [ChatMessage] = []

    var body: some View {
        ChatThreadControllerBridge(
            groupName: currentGroupName,
            messages: messages,
            onBack: { dismiss() },
            onShowMembers: { showMembers = true },
            onSendTapped: { body in
                // Fire-and-forget. `SendMessageInteractor` does the
                // optimistic insert as `.pending` synchronously
                // before the await, so the new row appears in the
                // `MessageRepository.snapshots` stream we're
                // subscribing to above — the table updates without
                // any extra plumbing here. The interactor also
                // owns the status flip to `.sent` / `.failed`, so
                // a thrown error here would only indicate a
                // precondition violation (no identity, unknown
                // group). Those shouldn't happen mid-chat-screen;
                // swallow with `try?` for PR 8.
                let interactor = sendMessageInteractor
                let groupID = groupID
                Task {
                    try? await interactor.send(groupID: groupID, body: body)
                }
            }
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
        // Per-group subscription. `task(id:)` cancels + restarts when
        // groupID changes, so navigating into a different chat
        // doesn't leak the previous group's stream.
        .task(id: groupID) {
            for await snapshot in messageRepository.snapshots(groupID: groupID) {
                messages = snapshot
            }
        }
    }

    private var currentGroupName: String {
        chatsFlow.groups.first { $0.id == groupID }?.name ?? "Chat"
    }
}

private struct ChatThreadControllerBridge: UIViewControllerRepresentable {
    let groupName: String
    let messages: [ChatMessage]
    let onBack: () -> Void
    let onShowMembers: () -> Void
    let onSendTapped: (String) -> Void

    func makeUIViewController(context: Context) -> ChatThreadViewController {
        let vc = ChatThreadViewController()
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.onSendTapped = onSendTapped
        vc.loadViewIfNeeded()
        vc.update(groupName: groupName)
        vc.update(messages: messages)
        return vc
    }

    func updateUIViewController(_ vc: ChatThreadViewController, context: Context) {
        // Closures are refreshed every render — SwiftUI captures the
        // *current* `dismiss` + `showMembers` setters + send-tap
        // dispatcher, so the version the controller invokes always
        // reflects the live binding.
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.onSendTapped = onSendTapped
        vc.update(groupName: groupName)
        vc.update(messages: messages)
    }
}
