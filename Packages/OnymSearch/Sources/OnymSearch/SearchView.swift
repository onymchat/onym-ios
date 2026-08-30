import SwiftUI
import OnymIdentity
import OnymChatsCore

/// Search tab: full-text search across the active identity's chat
/// messages. Typing a query decrypts + scans this identity's message
/// bodies (via `MessageRepository.search`), lists the matches newest
/// first, and tapping a result opens that chat scrolled to — and
/// flashing — the matched message.
///
/// Results open within the Search tab's own navigation stack, so Back
/// returns to the results list. Search is scoped to the active identity,
/// consistent with the owner-scoping used everywhere else in the app.
public struct SearchView: View {
    let messageRepository: MessageRepository
    @Bindable var identitiesFlow: IdentitiesFlow
    let groupNameForID: @MainActor (String) -> String?
    let startChats: @MainActor () -> Void
    /// Leaves the Search tab for Chats. The search role hands its tab
    /// its own slot and takes the tab strip away while it is showing,
    /// so with the keyboard up there is nothing on screen to leave by —
    /// this is the way out.
    let onBackToChats: @MainActor () -> Void

    @State private var query = ""
    @State private var results: [MessageSearchResult] = []

    public init(
        messageRepository: MessageRepository,
        identitiesFlow: IdentitiesFlow,
        groupNameForID: @escaping @MainActor (String) -> String?,
        startChats: @escaping @MainActor () -> Void,
        onBackToChats: @escaping @MainActor () -> Void
    ) {
        self.messageRepository = messageRepository
        self.identitiesFlow = identitiesFlow
        self.groupNameForID = groupNameForID
        self.startChats = startChats
        self.onBackToChats = onBackToChats
    }

    public var body: some View {
        List(results) { result in
            NavigationLink(value: result) {
                SearchResultRow(result: result)
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
        .searchable(text: $query, prompt: "Search messages")
        .navigationTitle("Search")
        .task { startChats() }
        // `.task(id:)` cancels + restarts on every keystroke, which
        // doubles as the debounce (the sleep below is cancelled if the
        // user keeps typing).
        .task(id: query) { await runSearch(query) }
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ContentUnavailableView {
                Label("Search Messages", systemImage: "magnifyingglass")
            } description: {
                Text("Find messages across all your chats.")
            } actions: {
                Button("Back to chats", action: onBackToChats)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("search.back_to_chats")
            }
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

        results = matches.map { message in
            MessageSearchResult(
                messageID: message.id,
                groupID: message.groupID,
                groupName: groupNameForID(message.groupID) ?? "Chat",
                snippet: message.body,
                sentAt: message.sentAt
            )
        }
    }
}

/// One search hit: group name, a snippet of the matched message body,
/// and a relative date. `Hashable`/`Identifiable` so it can drive both
/// `List` identity and `navigationDestination(for:)`.
public struct MessageSearchResult: Identifiable, Hashable {
    public let messageID: UUID
    public let groupID: String
    public let groupName: String
    public let snippet: String
    public let sentAt: Date

    public var id: UUID { messageID }

    public init(messageID: UUID, groupID: String, groupName: String, snippet: String, sentAt: Date) {
        self.messageID = messageID
        self.groupID = groupID
        self.groupName = groupName
        self.snippet = snippet
        self.sentAt = sentAt
    }
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
