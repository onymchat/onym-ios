import Foundation
import Observation

/// One row on the Chats list: a group enriched with its latest-message
/// preview + unread count, used to render the subtitle + badge and to
/// order the list most-recent-message-first.
struct ChatListItem: Identifiable, Equatable, Sendable {
    let group: ChatGroup
    /// Latest message's one-line preview (subtitle), or `nil` when the
    /// group has no messages yet.
    let latestPreview: String?
    /// Latest message timestamp — the sort key (falls back to the group's
    /// `createdAt` when there are no messages).
    let latestAt: Date?
    /// Count of incoming messages received since the thread was last read.
    let unreadCount: Int

    var id: String { group.id }

    /// Effective sort key: newest message, else group creation time.
    var sortKey: Date { latestAt ?? group.createdAt }
}

/// Interactor for the Chats tab. Joins `GroupRepository.snapshots` with
/// per-group message aggregates (latest message + unread count) from
/// `MessageRepository`, publishing a `[ChatListItem]` sorted
/// most-recent-message-first. Recomputes on either a group change or a
/// message change (via `MessageRepository.changes()`), so a new/received
/// message re-sorts the list and updates the subtitle + unread badge live.
///
/// `groups` (the raw snapshot) is still published for callers that only
/// need the group list (e.g. the thread screen's owner resolution).
@MainActor
@Observable
final class ChatsFlow {
    /// Raw group snapshot for the active identity (unsorted-by-message).
    private(set) var groups: [ChatGroup] = []
    /// Enriched + sorted rows the chat list renders.
    private(set) var items: [ChatListItem] = []

    private let repository: GroupRepository
    private let messages: MessageRepository
    private var groupTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?

    init(repository: GroupRepository, messages: MessageRepository) {
        self.repository = repository
        self.messages = messages
    }

    /// Begin draining repository snapshots + the message-change signal.
    /// Idempotent.
    func start() {
        guard groupTask == nil else { return }
        groupTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.repository.snapshots {
                self.groups = snapshot
                await self.recompute()
            }
        }
        messageTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.messages.changes() {
                await self.recompute()
            }
        }
    }

    func stop() {
        groupTask?.cancel()
        groupTask = nil
        messageTask?.cancel()
        messageTask = nil
    }

    /// Mark a group read up to `date` (the newest message the user has
    /// seen) so the unread badge clears. No-op when `date` isn't newer
    /// than the stored marker (see `GroupRepository.markRead`).
    func markRead(groupID: String, upTo date: Date) async {
        guard let owner = groups.first(where: { $0.id == groupID })?.ownerIdentityID else { return }
        await repository.markRead(id: groupID, ownerID: owner, at: date)
    }

    /// Rebuild `items` from the current groups joined with each group's
    /// latest message + unread count.
    private func recompute() async {
        let currentGroups = groups
        var built: [ChatListItem] = []
        built.reserveCapacity(currentGroups.count)
        for group in currentGroups {
            let latest = await messages.latestMessage(
                groupID: group.id, owner: group.ownerIdentityID
            )
            let unread = await messages.unreadCount(
                groupID: group.id,
                owner: group.ownerIdentityID,
                since: group.lastReadAt ?? .distantPast
            )
            built.append(ChatListItem(
                group: group,
                latestPreview: latest?.chatListPreview,
                latestAt: latest?.sentAt,
                unreadCount: unread
            ))
        }
        built.sort { $0.sortKey > $1.sortKey }
        // The groups snapshot may have changed while we awaited; only
        // publish if we're still describing the current set.
        guard currentGroups.map(\.id) == groups.map(\.id) else { return }
        items = built
    }
}
