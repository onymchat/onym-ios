import SwiftUI

/// Search tab: full-text search across the active identity's chat
/// messages. Typing a query decrypts + scans this identity's message
/// bodies (via `MessageRepository.search`), lists the matches newest
/// first, and tapping a result opens that chat scrolled to — and
/// flashing — the matched message.
///
/// Results open within the Search tab's own navigation stack, so Back
/// returns to the results list. Search is scoped to the active identity,
/// consistent with the owner-scoping used everywhere else in the app.
struct SearchView: View {
    let messageRepository: MessageRepository
    @Bindable var chatsFlow: ChatsFlow
    @Bindable var identitiesFlow: IdentitiesFlow
    let sendMessageInteractor: SendMessageInteractor
    let chatReceiptSender: any ChatReceiptSending
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    let setGroupAvatar: @MainActor (String, Data?) async -> Void
    let imageLoader: ChatImageLoader
    let videoLoader: ChatVideoLoader
    let voiceLoader: ChatVoiceLoader

    @State private var query = ""
    @State private var results: [MessageSearchResult] = []

    var body: some View {
        List(results) { result in
            NavigationLink(value: result) {
                SearchResultRow(result: result)
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .searchable(text: $query, prompt: "Search messages")
        .navigationTitle("Search")
        .navigationDestination(for: MessageSearchResult.self) { result in
            ChatThreadView(
                groupID: result.groupID,
                chatsFlow: chatsFlow,
                identitiesFlow: identitiesFlow,
                messageRepository: messageRepository,
                sendMessageInteractor: sendMessageInteractor,
                chatReceiptSender: chatReceiptSender,
                makeShareInviteFlow: makeShareInviteFlow,
                setGroupAvatar: setGroupAvatar,
                imageLoader: imageLoader,
                videoLoader: videoLoader,
                voiceLoader: voiceLoader,
                scrollToMessageID: result.messageID
            )
        }
        .task { chatsFlow.start() }
        // `.task(id:)` cancels + restarts on every keystroke, which
        // doubles as the debounce (the sleep below is cancelled if the
        // user keeps typing).
        .task(id: query) { await runSearch(query) }
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ContentUnavailableView(
                "Search Messages",
                systemImage: "magnifyingglass",
                description: Text("Find messages across all your chats.")
            )
        } else if results.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        }
    }

    private func runSearch(_ rawQuery: String) async {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let owner = identitiesFlow.currentID else {
            results = []
            return
        }
        // Debounce — cancelled by `.task(id:)` if another keystroke lands.
        try? await Task.sleep(for: .milliseconds(200))
        if Task.isCancelled { return }

        let matches = await messageRepository.search(owner: owner, query: trimmed)
        if Task.isCancelled { return }

        let groupsByID = Dictionary(
            chatsFlow.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        results = matches.map { message in
            MessageSearchResult(
                messageID: message.id,
                groupID: message.groupID,
                groupName: groupsByID[message.groupID]?.name ?? "Chat",
                snippet: message.body,
                sentAt: message.sentAt
            )
        }
    }
}

/// One search hit: group name, a snippet of the matched message body,
/// and a relative date. `Hashable`/`Identifiable` so it can drive both
/// `List` identity and `navigationDestination(for:)`.
struct MessageSearchResult: Identifiable, Hashable {
    let messageID: UUID
    let groupID: String
    let groupName: String
    let snippet: String
    let sentAt: Date

    var id: UUID { messageID }
}

private struct SearchResultRow: View {
    let result: MessageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(result.groupName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(result.sentAt, format: .dateTime.month().day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(result.snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("search.result.\(result.messageID.uuidString)")
    }
}
