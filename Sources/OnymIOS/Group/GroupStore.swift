import Foundation

/// Persistence seam for chat groups. Async surface mirrors
/// `InvitationStore` (PR #16) so a concrete impl can serialise writes
/// on its own queue without forcing callers onto a specific actor.
///
/// `ChatGroup` itself is the domain shape; the store is responsible
/// for AES-GCM-wrapping the sensitive columns at the boundary.
protocol GroupStore: Sendable {
    func list() async -> [ChatGroup]

    /// Idempotent on `ChatGroup.id`: if the row exists, sensitive +
    /// mutable fields are overwritten in place (so a chain-anchor
    /// retry can flip `isPublishedOnChain` and bump the commitment
    /// without losing the original `createdAt`). Returns `true` on
    /// insert, `false` on update.
    @discardableResult
    func insertOrUpdate(_ group: ChatGroup) async -> Bool

    /// Convenience for the post-anchor flow: flip
    /// `isPublishedOnChain` to true and update the commitment to
    /// whatever the relayer's `get_state` returned. No-op if the row
    /// is missing. Scoped to the composite `(id, ownerIDString)` so a
    /// group joined by more than one local identity flips only the
    /// creating identity's row.
    func markPublished(id: String, ownerIDString: String, commitment: Data?) async

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
