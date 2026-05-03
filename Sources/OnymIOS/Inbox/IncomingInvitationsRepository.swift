import Foundation

/// Domain shape for a received invitation as exposed to interactors and
/// (eventually) views. Re-exports `IncomingInvitationRecord` from the
/// persistence seam under a more idiomatic name; identical fields.
typealias IncomingInvitation = IncomingInvitationRecord

/// Owns the `InvitationStore` and exposes a per-identity reactive
/// snapshots stream. Multi-identity-aware (post #58): the cached list
/// always holds the full on-disk roster; subscribers receive the
/// current identity's rows only. Switching identity re-emits with the
/// new filter applied — same shape `GroupRepository` uses.
///
/// Interactors call `recordIncoming` / `updateStatus` / `delete` and
/// observe `snapshots`; the app shell wires `setCurrentIdentity` /
/// `removeForOwner` from `IdentityRepository`'s streams.
actor IncomingInvitationsRepository {
    private let store: any InvitationStore
    /// Full on-disk roster, unfiltered. Filter applies at yield time
    /// so a switch to a previously-loaded identity is instant.
    private var cached: [IncomingInvitation] = []
    private var currentIdentityID: IdentityID?
    private var continuations: [UUID: AsyncStream<[IncomingInvitation]>.Continuation] = [:]

    init(store: any InvitationStore, currentIdentityID: IdentityID? = nil) {
        self.store = store
        self.currentIdentityID = currentIdentityID
    }

    /// Idempotent on `id`. Returns `true` when a new invitation was
    /// inserted, `false` if `id` was already present (subscribers don't
    /// see a snapshot in the no-op case).
    @discardableResult
    func recordIncoming(
        id: String,
        ownerIdentityID: IdentityID,
        payload: Data,
        receivedAt: Date
    ) async -> Bool {
        let record = IncomingInvitation(
            id: id,
            ownerIdentityID: ownerIdentityID,
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

    /// Drop every invitation owned by `id`. Wired into
    /// `IdentityRepository.identityRemoved` by the app shell so
    /// removing an identity wipes its inbound queue too.
    func removeForOwner(_ id: IdentityID) async {
        await store.deleteOwner(id.rawValue.uuidString)
        await refreshFromStore()
    }

    /// Set the identity whose invitations subscribers should see.
    /// Re-emits the filtered list; pass `nil` to broadcast empty.
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

    private func filteredCache() -> [IncomingInvitation] {
        guard let currentIdentityID else { return [] }
        return cached.filter { $0.ownerIdentityID == currentIdentityID }
    }
}
