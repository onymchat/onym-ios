import Foundation

/// Domain shape for a received invitation as exposed to interactors and
/// (eventually) views. Re-exports `IncomingInvitationRecord` from the
/// persistence seam under a more idiomatic name; identical fields.
typealias IncomingInvitation = IncomingInvitationRecord

/// Owns the `InvitationStore` and exposes a reactive snapshots stream.
/// Mirrors `IdentityRepository`'s shape: every successful mutation is
/// followed by a fresh snapshot pushed to all subscribers; the current
/// list is replayed on every new subscribe.
///
/// This is the only thing in the codebase that holds an `InvitationStore`
/// reference. Interactors call `recordIncoming` / `updateStatus` /
/// `delete` and observe `snapshots`; views observe via an interactor.
actor IncomingInvitationsRepository {
    private let store: any InvitationStore
    private var cached: [IncomingInvitation] = []
    private var continuations: [UUID: AsyncStream<[IncomingInvitation]>.Continuation] = [:]

    init(store: any InvitationStore) {
        self.store = store
    }

    /// Idempotent on `id`. Returns `true` when a new invitation was
    /// inserted, `false` if `id` was already present (subscribers don't
    /// see a snapshot in the no-op case).
    @discardableResult
    func recordIncoming(
        id: String,
        payload: Data,
        receivedAt: Date
    ) async -> Bool {
        let record = IncomingInvitation(
            id: id,
            payload: payload,
            receivedAt: receivedAt,
            status: .pending
        )
        let inserted = await store.save(record)
        guard inserted else { return false }
        await refreshFromStore()
        return true
    }

    func updateStatus(id: String, status: IncomingInvitationStatus) async {
        await store.updateStatus(id: id, status: status)
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

    nonisolated var snapshots: AsyncStream<[IncomingInvitation]> {
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
        continuation: AsyncStream<[IncomingInvitation]>.Continuation
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
