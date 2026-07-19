import Foundation

/// Persistence seam for chat messages. Async surface mirrors
/// `GroupStore` so a concrete implementation can serialise writes on
/// its own queue without forcing callers onto a specific actor.
///
/// `ChatMessage` itself is the domain shape; the store is responsible
/// for AES-GCM-wrapping the sensitive columns at the boundary.
protocol MessageStore: Sendable {
    /// All messages for one group owned by `ownerIDString`, sorted by
    /// `sentAt` ascending — chronological order is what the chat
    /// scroll renders. Scoped to the owner so that when two local
    /// identities are both in a group each thread shows only its own
    /// rows (and its own send/receive direction).
    func list(groupID: String, ownerIDString: String) async -> [ChatMessage]

    /// The most recent message (any direction) for one group owned by
    /// `ownerIDString`, or `nil` when the group has no messages. Drives
    /// the chat-list row subtitle + the list's most-recent-first sort.
    func latestMessage(groupID: String, ownerIDString: String) async -> ChatMessage?

    /// Count of *incoming* messages in one group (owned by `ownerIDString`)
    /// received after `since` — the chat-list unread badge. `since` is the
    /// group's last-read marker; pass `.distantPast` to count everything.
    /// Uses only plain (unencrypted) columns, so it's a cheap fetch-count.
    func unreadCount(groupID: String, ownerIDString: String, since: Date) async -> Int

    /// Case-insensitive substring search over one identity's message
    /// bodies across all groups, newest first (capped at `limit`). Bodies
    /// are encrypted at rest, so the store decrypts and filters in memory.
    /// An empty query returns nothing.
    func search(ownerIDString: String, query: String, limit: Int) async -> [ChatMessage]

    /// Idempotent on the composite `(message.id, ownerIdentityID)`.
    /// New row → insert. Same id+owner → update in place; used both
    /// for receive-side replays (no-op result on the second insert)
    /// and outgoing status transitions (pending → sent / failed).
    /// Returns `true` on insert, `false` on update.
    @discardableResult
    func insertOrUpdate(_ message: ChatMessage) async -> Bool

    /// Flip just the status column (and the failure-reason column that
    /// travels with it — non-nil when flipping to `.failed`, nil
    /// otherwise so a retry's pending flip clears the stale reason).
    /// Convenience for the outgoing pipeline so we don't have to
    /// round-trip the whole row through the encryption boundary just
    /// to bump pending → sent. No-op if the `(id, owner)` row is
    /// missing.
    func updateStatus(id: UUID, ownerIDString: String, status: MessageStatus, failureReason: SendFailureReason?) async

    func delete(id: UUID, ownerIDString: String) async

    /// Drop every message for one group owned by `ownerIDString` —
    /// wired into the group-delete path so removing a group wipes its
    /// messages too, without touching another identity's copy of the
    /// same group.
    func deleteGroup(groupID: String, ownerIDString: String) async

    /// Cascade delete for `IdentityRepository.identityRemoved`. Same
    /// pattern as `GroupStore.deleteOwner`.
    func deleteOwner(_ ownerIDString: String) async

    /// Wipe every message across all owners and groups (the Settings
    /// "clear local message cache" action). Groups/chats live in a
    /// separate store and are untouched.
    func deleteAll() async
}
