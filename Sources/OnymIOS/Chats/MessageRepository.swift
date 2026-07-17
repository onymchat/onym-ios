import Foundation

/// Owns the `MessageStore` and exposes a per-group reactive snapshots
/// stream. Mirrors `GroupRepository`: every successful mutation is
/// followed by a fresh snapshot pushed to that group's subscribers;
/// the current list is replayed on every new subscribe.
///
/// Keyed by groupID instead of by current identity because the chat
/// screen subscribes to exactly one group at a time, and identity
/// scope is already enforced upstream (only groups the active
/// identity owns appear in the list, so only those will have a thread
/// opened).
actor MessageRepository {
    private let store: any MessageStore

    /// Per-group cache. Populated lazily on first subscribe or
    /// mutation; one entry per group the UI has touched this session.
    /// Kept narrow on purpose — the chat thread reads one group at a
    /// time, so loading the entire messages table at startup would be
    /// wasted I/O.
    private var cached: [String: [ChatMessage]] = [:]

    private var continuations: [String: [UUID: AsyncStream<[ChatMessage]>.Continuation]] = [:]

    init(store: any MessageStore) {
        self.store = store
    }

    // MARK: - Mutations

    /// Idempotent on `message.id` (delegates to
    /// `MessageStore.insertOrUpdate`). Receive-side replays and
    /// outgoing status flips both flow through here.
    @discardableResult
    func insert(_ message: ChatMessage) async -> Bool {
        let inserted = await store.insertOrUpdate(message)
        await refresh(groupID: message.groupID)
        return inserted
    }

    /// Flip an outgoing message's status (pending → sent / failed).
    /// Hot path for the send pipeline so we don't round-trip the
    /// whole row through the encryption boundary. `failureReason`
    /// travels with the status: pass the category when flipping to
    /// `.failed`, leave it nil for every other status so a retry's
    /// pending flip clears the stale reason.
    func updateStatus(
        id: UUID,
        status: MessageStatus,
        groupID: String,
        failureReason: SendFailureReason? = nil
    ) async {
        await store.updateStatus(id: id, status: status, failureReason: failureReason)
        await refresh(groupID: groupID)
    }

    func delete(id: UUID, groupID: String) async {
        await store.delete(id: id)
        await refresh(groupID: groupID)
    }

    /// Drop every message for one group. Wired into the group-delete
    /// path so removing a group wipes its thread.
    func removeForGroup(_ groupID: String) async {
        await store.deleteGroup(groupID: groupID)
        cached[groupID] = []
        publish(groupID: groupID)
    }

    /// Cascade delete on identity removal. The store drops rows whose
    /// `ownerIdentityID` matches; rows in the same group owned by a
    /// different identity stay put, so each cached group has to be
    /// refreshed (not wiped) and re-published.
    func removeForOwner(_ id: IdentityID) async {
        await store.deleteOwner(id.rawValue.uuidString)
        let groupIDs = Array(cached.keys)
        for groupID in groupIDs {
            await refresh(groupID: groupID)
        }
    }

    // MARK: - Subscriptions

    /// Reactive stream of messages for one group. Emits the current
    /// snapshot on subscribe and on every mutation that touches this
    /// group. Other groups' mutations are silent.
    nonisolated func snapshots(groupID: String) -> AsyncStream<[ChatMessage]> {
        AsyncStream { continuation in
            let subscriberID = UUID()
            Task {
                await self.subscribe(
                    groupID: groupID,
                    subscriberID: subscriberID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(groupID: groupID, subscriberID: subscriberID) }
            }
        }
    }

    /// One-shot read. Useful for tests and for paths that need to
    /// look at the current list without keeping a subscription.
    func currentMessages(groupID: String) async -> [ChatMessage] {
        if cached[groupID] == nil { await refresh(groupID: groupID) }
        return cached[groupID] ?? []
    }

    // MARK: - Private

    private func subscribe(
        groupID: String,
        subscriberID: UUID,
        continuation: AsyncStream<[ChatMessage]>.Continuation
    ) async {
        if cached[groupID] == nil {
            await refresh(groupID: groupID)
        }
        continuations[groupID, default: [:]][subscriberID] = continuation
        continuation.yield(cached[groupID] ?? [])
    }

    private func unsubscribe(groupID: String, subscriberID: UUID) {
        continuations[groupID]?.removeValue(forKey: subscriberID)
        if continuations[groupID]?.isEmpty == true {
            continuations.removeValue(forKey: groupID)
        }
    }

    private func refresh(groupID: String) async {
        cached[groupID] = await store.list(groupID: groupID)
        publish(groupID: groupID)
    }

    private func publish(groupID: String) {
        let view = cached[groupID] ?? []
        guard let subscribers = continuations[groupID] else { return }
        for continuation in subscribers.values {
            continuation.yield(view)
        }
    }
}
