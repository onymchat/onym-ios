import Foundation

/// Owns the `GroupStore` and exposes a reactive snapshots stream.
/// Mirrors `IncomingInvitationsRepository`: every successful mutation
/// is followed by a fresh snapshot pushed to all subscribers; the
/// current list is replayed on every new subscribe.
///
/// This is the only thing in the codebase that holds a `GroupStore`
/// reference. PR-C's `CreateGroupInteractor` calls `insert` /
/// `markPublished` / `delete` and observes `snapshots`; views observe
/// via the interactor.
actor GroupRepository {
    private let store: any GroupStore
    private var cached: [ChatGroup] = []
    private var continuations: [UUID: AsyncStream<[ChatGroup]>.Continuation] = [:]

    init(store: any GroupStore) {
        self.store = store
    }

    /// Idempotent on `group.id` (delegates to
    /// `GroupStore.insertOrUpdate`). Any subsequent insert with the
    /// same id overwrites the row in place — the chain-anchor flow
    /// uses this to flip `isPublishedOnChain` and bump the
    /// commitment.
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

    /// Force a refresh from the backing store. Used at app launch and
    /// by tests; mutators call it themselves.
    func reload() async {
        await refreshFromStore()
    }

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
        continuation.yield(cached)
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func refreshFromStore() async {
        cached = await store.list()
        for continuation in continuations.values {
            continuation.yield(cached)
        }
    }
}
