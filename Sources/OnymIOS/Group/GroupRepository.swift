import Foundation

/// Owns the `GroupStore` and exposes a per-identity reactive snapshots
/// stream. Mirrors `IncomingInvitationsRepository`: every successful
/// mutation is followed by a fresh snapshot pushed to all subscribers;
/// the current list is replayed on every new subscribe.
///
/// PR-3 of the multi-identity stack: the cached list always holds the
/// full on-disk roster; subscribers receive the current identity's
/// rows only. Switching identity (`setCurrentIdentity`) re-emits with
/// the new filter applied.
actor GroupRepository {
    private let store: any GroupStore
    /// Full on-disk roster, unfiltered. The filter applies at yield
    /// time so a switch to a previously-loaded identity is instant —
    /// no fresh `store.list()` round-trip.
    private var cached: [ChatGroup] = []
    private var currentIdentityID: IdentityID?
    private var continuations: [UUID: AsyncStream<[ChatGroup]>.Continuation] = [:]

    init(store: any GroupStore, currentIdentityID: IdentityID? = nil) {
        self.store = store
        self.currentIdentityID = currentIdentityID
    }

    // MARK: - Mutations

    /// Idempotent on `group.id` (delegates to
    /// `GroupStore.insertOrUpdate`). Any subsequent insert with the
    /// same id overwrites the row in place — the chain-anchor flow
    /// uses this to flip `isPublishedOnChain` and bump the commitment.
    @discardableResult
    func insert(_ group: ChatGroup) async -> Bool {
        let inserted = await store.insertOrUpdate(group)
        await refreshFromStore()
        return inserted
    }

    /// Mark a group as anchored on chain. The commitment, when
    /// supplied, replaces whatever was held in memory (the relayer's
    /// `get_state` is the source of truth post-anchor).
    func markPublished(id: String, commitment: Data?) async {
        await store.markPublished(id: id, commitment: commitment)
        await refreshFromStore()
    }

    func delete(id: String) async {
        await store.delete(id: id)
        await refreshFromStore()
    }

    /// Drop every group owned by `id`. Wired into
    /// `IdentityRepository.identityRemoved` by the app shell so
    /// removing an identity wipes its chats too.
    func removeForOwner(_ id: IdentityID) async {
        await store.deleteOwner(id.rawValue.uuidString)
        await refreshFromStore()
    }

    // MARK: - Identity selection

    /// Set the identity whose groups subscribers should see. Re-emits
    /// the filtered list to every active subscriber. Pass `nil` (e.g.
    /// after the last identity is removed) to broadcast an empty list.
    func setCurrentIdentity(_ id: IdentityID?) {
        guard currentIdentityID != id else { return }
        currentIdentityID = id
        publishFiltered()
    }

    /// Force a refresh from the backing store. Used at app launch and
    /// by tests; mutators call it themselves.
    func reload() async {
        await refreshFromStore()
    }

    /// One-shot read of every cached group across **all** identities.
    /// Used by `JoinRequestApprover` to look up a group by its raw
    /// `group_id` bytes — the request can name any group on the
    /// device, and the lookup must succeed regardless of which
    /// identity is currently selected. Subscribers prefer
    /// `snapshots`.
    func currentGroups() async -> [ChatGroup] {
        if cached.isEmpty { await refreshFromStore() }
        return cached
    }

    // MARK: - Subscriptions

    nonisolated var snapshots: AsyncStream<[ChatGroup]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<[ChatGroup]>.Continuation
    ) async {
        if cached.isEmpty {
            await refreshFromStore()
        }
        continuations[id] = continuation
        continuation.yield(filteredCache())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func refreshFromStore() async {
        cached = await store.list()
        publishFiltered()
    }

    private func publishFiltered() {
        let view = filteredCache()
        for continuation in continuations.values {
            continuation.yield(view)
        }
    }

    private func filteredCache() -> [ChatGroup] {
        guard let currentIdentityID else { return [] }
        return cached.filter { $0.ownerIdentityID == currentIdentityID }
    }
}
