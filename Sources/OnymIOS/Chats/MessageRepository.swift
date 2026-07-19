import Foundation

/// Owns the `MessageStore` and exposes a reactive snapshots stream per
/// `(group, owner identity)`. Mirrors `GroupRepository`: every
/// successful mutation is followed by a fresh snapshot pushed to that
/// thread's subscribers; the current list is replayed on every new
/// subscribe.
///
/// Keyed by `(groupID, owner)` rather than `groupID` alone because the
/// same on-chain group can be joined by more than one local identity
/// on a single device (e.g. one identity invites another to the same
/// chat). Each identity keeps its own thread — its own messages and
/// its own send/receive direction. The inbox fan-out delivers to every
/// identity's inbox concurrently regardless of which one is selected
/// (`InboxFanoutInteractor`), so the owner has to be explicit rather
/// than inferred from a "current identity".
actor MessageRepository {
    private let store: any MessageStore

    /// Identifies one chat thread: a group as seen by one local
    /// identity.
    private struct ThreadKey: Hashable {
        let groupID: String
        let owner: IdentityID
    }

    /// Per-thread cache. Populated lazily on first subscribe or
    /// mutation; one entry per thread the app has touched this session.
    /// Kept narrow on purpose — the chat screen reads one thread at a
    /// time, so loading the entire messages table at startup would be
    /// wasted I/O.
    private var cached: [ThreadKey: [ChatMessage]] = [:]

    private var continuations: [ThreadKey: [UUID: AsyncStream<[ChatMessage]>.Continuation]] = [:]

    /// Subscribers to the coarse cross-thread "something changed" signal
    /// (see `changes()`). Keyed by a per-subscriber UUID.
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(store: any MessageStore) {
        self.store = store
    }

    // MARK: - Mutations

    /// Idempotent on `(message.id, message.ownerIdentityID)` (delegates
    /// to `MessageStore.insertOrUpdate`). Receive-side replays and
    /// outgoing status flips both flow through here.
    @discardableResult
    func insert(_ message: ChatMessage) async -> Bool {
        let inserted = await store.insertOrUpdate(message)
        await refresh(ThreadKey(groupID: message.groupID, owner: message.ownerIdentityID))
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
        owner: IdentityID,
        failureReason: SendFailureReason? = nil
    ) async {
        await store.updateStatus(
            id: id,
            ownerIDString: owner.rawValue.uuidString,
            status: status,
            failureReason: failureReason
        )
        await refresh(ThreadKey(groupID: groupID, owner: owner))
    }

    /// Raise an outgoing message's delivery status from an inbound
    /// receipt, never lowering it. No-op unless the row exists, is
    /// outgoing, and `status` sits strictly higher on the delivery
    /// ladder than the current value (so a late `.delivered` arriving
    /// after `.read`, a duplicate receipt, or a receipt for an unknown /
    /// incoming / failed row all do nothing). See
    /// `MessageStatus.deliveryRank`.
    func upgradeStatus(id: UUID, to status: MessageStatus, groupID: String, owner: IdentityID) async {
        guard let newRank = status.deliveryRank else { return }
        let messages = await currentMessages(groupID: groupID, owner: owner)
        guard let message = messages.first(where: { $0.id == id }),
              message.direction == .outgoing,
              let currentRank = message.status.deliveryRank,
              newRank > currentRank
        else { return }
        await updateStatus(id: id, status: status, groupID: groupID, owner: owner)
    }

    func delete(id: UUID, groupID: String, owner: IdentityID) async {
        await store.delete(id: id, ownerIDString: owner.rawValue.uuidString)
        await refresh(ThreadKey(groupID: groupID, owner: owner))
    }

    /// Drop every message for one thread. Wired into the group-delete
    /// path so removing a chat wipes its thread — scoped to the owner
    /// so another identity's copy of the same group is untouched.
    func removeForGroup(_ groupID: String, owner: IdentityID) async {
        await store.deleteGroup(groupID: groupID, ownerIDString: owner.rawValue.uuidString)
        let key = ThreadKey(groupID: groupID, owner: owner)
        cached[key] = []
        publish(key)
        notifyChange()
    }

    /// Cascade delete on identity removal. The store drops every row
    /// whose `ownerIdentityID` matches; only that identity's cached
    /// threads need refreshing (other identities' rows — including in
    /// the same group — stay put).
    func removeForOwner(_ id: IdentityID) async {
        await store.deleteOwner(id.rawValue.uuidString)
        let keys = cached.keys.filter { $0.owner == id }
        for key in keys {
            await refresh(key)
        }
    }

    /// Wipe every message on the device (Settings "clear local message
    /// cache"). Chats/groups are a separate store and survive. Empties
    /// every cached thread and republishes so open chats and the chat
    /// list update live.
    func removeAll() async {
        await store.deleteAll()
        for key in cached.keys {
            cached[key] = []
            publish(key)
        }
        notifyChange()
    }

    // MARK: - Subscriptions

    /// Reactive stream of messages for one thread. Emits the current
    /// snapshot on subscribe and on every mutation that touches this
    /// thread. Other threads' mutations are silent.
    nonisolated func snapshots(groupID: String, owner: IdentityID) -> AsyncStream<[ChatMessage]> {
        AsyncStream { continuation in
            let subscriberID = UUID()
            let key = ThreadKey(groupID: groupID, owner: owner)
            Task {
                await self.subscribe(
                    key: key,
                    subscriberID: subscriberID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(key: key, subscriberID: subscriberID) }
            }
        }
    }

    /// One-shot read. Useful for tests and for paths that need to
    /// look at the current thread without keeping a subscription.
    func currentMessages(groupID: String, owner: IdentityID) async -> [ChatMessage] {
        let key = ThreadKey(groupID: groupID, owner: owner)
        if cached[key] == nil { await refresh(key) }
        return cached[key] ?? []
    }

    /// Case-insensitive substring search over `owner`'s message bodies
    /// across every group, newest first. Delegates straight to the store
    /// (no per-thread caching — search is a cold, cross-group read).
    func search(owner: IdentityID, query: String, limit: Int = 200) async -> [ChatMessage] {
        await store.search(
            ownerIDString: owner.rawValue.uuidString, query: query, limit: limit
        )
    }

    // MARK: - Chat-list aggregates

    /// The most recent message for one thread (chat-list subtitle + sort).
    func latestMessage(groupID: String, owner: IdentityID) async -> ChatMessage? {
        await store.latestMessage(
            groupID: groupID, ownerIDString: owner.rawValue.uuidString
        )
    }

    /// Count of incoming messages in one thread received after `since`
    /// (chat-list unread badge).
    func unreadCount(groupID: String, owner: IdentityID, since: Date) async -> Int {
        await store.unreadCount(
            groupID: groupID, ownerIDString: owner.rawValue.uuidString, since: since
        )
    }

    /// Coarse "some thread's messages changed" signal — fires on any
    /// insert / status flip / delete (and once on subscribe, to prime).
    /// The chat list listens so it can recompute each group's latest
    /// message + unread count and re-sort; the payload is intentionally
    /// empty (the list re-reads the store cheaply on each ping).
    nonisolated func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addChangeSubscriber(id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeChangeSubscriber(id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(
        key: ThreadKey,
        subscriberID: UUID,
        continuation: AsyncStream<[ChatMessage]>.Continuation
    ) async {
        if cached[key] == nil {
            await refresh(key)
        }
        continuations[key, default: [:]][subscriberID] = continuation
        continuation.yield(cached[key] ?? [])
    }

    private func unsubscribe(key: ThreadKey, subscriberID: UUID) {
        continuations[key]?.removeValue(forKey: subscriberID)
        if continuations[key]?.isEmpty == true {
            continuations.removeValue(forKey: key)
        }
    }

    private func refresh(_ key: ThreadKey) async {
        cached[key] = await store.list(
            groupID: key.groupID,
            ownerIDString: key.owner.rawValue.uuidString
        )
        publish(key)
        notifyChange()
    }

    private func publish(_ key: ThreadKey) {
        let view = cached[key] ?? []
        guard let subscribers = continuations[key] else { return }
        for continuation in subscribers.values {
            continuation.yield(view)
        }
    }

    private func addChangeSubscriber(
        _ id: UUID,
        _ continuation: AsyncStream<Void>.Continuation
    ) {
        changeContinuations[id] = continuation
        continuation.yield(())  // prime so the list computes immediately
    }

    private func removeChangeSubscriber(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    private func notifyChange() {
        for continuation in changeContinuations.values { continuation.yield(()) }
    }
}
