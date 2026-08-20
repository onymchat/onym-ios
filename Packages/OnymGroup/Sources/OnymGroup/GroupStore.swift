import Foundation

/// Result of `GroupStore.insertOrUpdate`. Mirrors
/// `MessageInsertOutcome` case for case, and deliberately is not the
/// same type: the three stores agree on the *shape* of the answer, not
/// on what the middle case means. A group `.updated` was overwritten in
/// place — the row on disk now holds the new field values.
/// `InvitationSaveOutcome.duplicate` is the opposite, a write the store
/// declined so the original row survives untouched. A shared enum would
/// have to pick one of those two words and be wrong about the other
/// store every time someone read it, which is the class of confusion
/// this type exists to end. (All three modules do hang off
/// `OnymFoundation`, so a common type was available and was not the
/// thing standing in the way.)
///
/// What every one of them *does* share is that the last case is
/// distinct: "nothing was persisted" can never again be spelled the
/// same way as "persisted, just not as a new row".
public enum GroupInsertOutcome: Sendable, Equatable {
    /// New row persisted.
    case inserted
    /// A row with the same `(id, owner)` already existed and its
    /// sensitive + mutable fields were overwritten in place.
    case updated
    /// Nothing was persisted — encode gave way.
    case failed
}

/// Persistence seam for chat groups. Async surface mirrors
/// `InvitationStore` (PR #16) so a concrete impl can serialise writes
/// on its own queue without forcing callers onto a specific actor.
///
/// `ChatGroup` itself is the domain shape; the store is responsible
/// for AES-GCM-wrapping the sensitive columns at the boundary.
public protocol GroupStore: Sendable {
    func list() async -> [ChatGroup]

    /// Idempotent on `ChatGroup.id`: if the row exists, sensitive +
    /// mutable fields are overwritten in place (so a chain-anchor
    /// retry can flip `isPublishedOnChain` and bump the commitment
    /// without losing the original `createdAt`).
    ///
    /// This used to answer `Bool` — `true` on insert, `false` on
    /// update — and the `false` was doing two jobs, because the encode
    /// guard returns it too having written nothing. Every caller that
    /// only ever asks "did that work?" reads `false` and gets no answer.
    /// The backup sink hit this for real: counting `false` as a failure
    /// reports every restore onto a device that already holds rows as
    /// unreadable, and counting it as a success reports a store that
    /// refused the write as restored.
    @discardableResult
    func insertOrUpdate(_ group: ChatGroup) async -> GroupInsertOutcome

    /// Convenience for the post-anchor flow: flip
    /// `isPublishedOnChain` to true and update the commitment to
    /// whatever the relayer's `get_state` returned. No-op if the row
    /// is missing. Scoped to the composite `(id, ownerIDString)` so a
    /// group joined by more than one local identity flips only the
    /// creating identity's row.
    func markPublished(id: String, ownerIDString: String, commitment: Data?) async

    /// Stamp the group's last-read marker (chat-list unread badge). No-op
    /// if the row is missing. Scoped to `(id, ownerIDString)` so opening a
    /// thread as one identity doesn't clear another identity's unread
    /// state for the same group.
    func markRead(id: String, ownerIDString: String, at date: Date) async

    /// Delete the single row for `(id, ownerIDString)`. Scoped to the
    /// owner so deleting a chat for one identity leaves another
    /// identity's copy of the same group intact.
    func delete(id: String, ownerIDString: String) async

    /// Delete every row whose `ownerIdentityIDString` matches.
    /// `ownerIDString` is the UUID-string form of the removed
    /// `IdentityID`. Used by the identity-removal hook in
    /// `GroupRepository.removeForOwner`.
    func deleteOwner(_ ownerIDString: String) async
}
