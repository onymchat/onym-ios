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
    let chatReceiptSender: any ChatReceiptSending
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let setGroupAvatar: @MainActor (String, Data?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showMembers: Bool = false
    /// Incoming message IDs we've already emitted a read receipt for,
    /// so re-renders while the thread stays open don't re-send.
    @State private var ackedReadIDs: Set<UUID> = []
    /// Live snapshot of the group's messages, sorted ascending by
    /// `sentAt`. SwiftUI re-renders on every push so the bridge
    /// hands the controller fresh data via `updateUIViewController`.
    @State private var messages: [ChatMessage] = []

    var body: some View {
        ChatThreadControllerBridge(
            groupName: currentGroupName,
            memberCount: currentMemberCount,
            memberProfiles: currentMemberProfiles,
            messages: messages,
            onBack: { dismiss() },
            onShowMembers: { showMembers = true },
            onSendTapped: { body, replyToMessageID in
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
                // swallow with `try?`.
                let interactor = sendMessageInteractor
                let groupID = groupID
                Task {
                    try? await interactor.send(
                        groupID: groupID,
                        body: body,
                        replyToMessageID: replyToMessageID
                    )
                }
            },
            onRetryRequested: { messageID in
                // PR 9: retry a failed outgoing message. Same
                // fire-and-forget shape as the send path — the
                // interactor flips status to .pending before the
                // network work begins (so the glyph swaps to the
                // in-flight clock immediately), runs the fan-out,
                // then flips to .sent / .failed on completion.
                let interactor = sendMessageInteractor
                let groupID = groupID
                Task {
                    await interactor.retry(groupID: groupID, messageID: messageID)
                }
            }
        )
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $showMembers) {
            ChatMembersView(
                groupID: groupID,
                chatsFlow: chatsFlow,
                identitiesFlow: identitiesFlow,
                makeShareInviteFlow: makeShareInviteFlow,
                setGroupAvatar: setGroupAvatar
            )
        }
        // Per-group subscription. `task(id:)` cancels + restarts when
        // groupID changes, so navigating into a different chat
        // doesn't leak the previous group's stream.
        .task(id: groupID) {
            for await snapshot in messageRepository.snapshots(groupID: groupID) {
                messages = snapshot
                // Read receipts: the thread is on-screen (this task is
                // tied to its lifetime), so any incoming message here is
                // "read". Gated by the symmetric setting, batched per
                // sender, and de-duped via `ackedReadIDs`.
                await sendReadReceipts(for: snapshot)
            }
        }
    }

    /// Emit `.read` receipts for incoming messages the user is now
    /// looking at. No-op when the setting is off. Groups unacked
    /// incoming IDs by sender and ships one receipt per sender to that
    /// sender's inbox key (resolved from the group's member profiles).
    private func sendReadReceipts(for snapshot: [ChatMessage]) async {
        guard ReadReceiptsPreference.isEnabled else { return }
        guard let group = chatsFlow.groups.first(where: { $0.id == groupID }) else { return }
        var bySender: [String: [UUID]] = [:]
        for message in snapshot
        where message.direction == .incoming && !ackedReadIDs.contains(message.id) {
            bySender[message.senderBlsPubkeyHex, default: []].append(message.id)
        }
        guard !bySender.isEmpty else { return }
        for (senderHex, ids) in bySender {
            guard let inbox = group.memberProfiles[senderHex]?.inboxPublicKey else { continue }
            await chatReceiptSender.send(
                kind: .read,
                messageIDs: ids,
                groupID: group.groupIDData,
                to: inbox
            )
            for id in ids { ackedReadIDs.insert(id) }
        }
    }

    private var currentGroupName: String {
        chatsFlow.groups.first { $0.id == groupID }?.name ?? "Chat"
    }

    /// Drives the title subtitle ("N members"). Reads from the same
    /// `chatsFlow.groups` source as the name so an admin admitting
    /// a new joiner updates the bar live as the announcement lands.
    private var currentMemberCount: Int {
        chatsFlow.groups.first { $0.id == groupID }?.memberProfiles.count ?? 0
    }

    /// Member profiles for the current group, keyed by BLS pubkey hex.
    /// Feeds the chat thread's sender-name resolution. Reads from the
    /// same `chatsFlow.groups` source as the name/count so it stays
    /// live as joiners land or aliases change.
    private var currentMemberProfiles: [String: MemberProfile] {
        chatsFlow.groups.first { $0.id == groupID }?.memberProfiles ?? [:]
    }
}

private struct ChatThreadControllerBridge: UIViewControllerRepresentable {
    let groupName: String
    let memberCount: Int
    let memberProfiles: [String: MemberProfile]
    let messages: [ChatMessage]
    let onBack: () -> Void
    let onShowMembers: () -> Void
    let onSendTapped: (String, UUID?) -> Void
    let onRetryRequested: (UUID) -> Void

    func makeUIViewController(context: Context) -> ChatThreadViewController {
        let vc = ChatThreadViewController()
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.onSendTapped = onSendTapped
        vc.onRetryRequested = onRetryRequested
        vc.loadViewIfNeeded()
        vc.update(groupName: groupName, memberCount: memberCount)
        // Profiles before messages — the first sender-display build
        // reads the profiles to resolve names.
        vc.update(memberProfiles: memberProfiles)
        vc.update(messages: messages)
        return vc
    }

    func updateUIViewController(_ vc: ChatThreadViewController, context: Context) {
        // Closures are refreshed every render — SwiftUI captures the
        // *current* `dismiss` + `showMembers` setters + send-tap
        // dispatcher + retry dispatcher, so the version the
        // controller invokes always reflects the live binding.
        vc.onBack = onBack
        vc.onShowMembers = onShowMembers
        vc.onSendTapped = onSendTapped
        vc.onRetryRequested = onRetryRequested
        vc.update(groupName: groupName, memberCount: memberCount)
        vc.update(memberProfiles: memberProfiles)
        vc.update(messages: messages)
    }
}
