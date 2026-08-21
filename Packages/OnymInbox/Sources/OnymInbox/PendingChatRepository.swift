import Foundation
import OnymIdentity

/// Owns a `PendingChatStore` and exposes a per-identity reactive
/// snapshots stream. Deliberately the same shape as `GroupRepository`,
/// because it feeds the same list: every mutation is followed by a fresh
/// snapshot to all subscribers, and the current list is replayed to each
/// new subscriber.
///
/// The cache holds every row on the device; the identity filter is
/// applied at yield time, so switching back to an identity is instant
/// and no `store.list()` round-trip is needed.
public actor PendingChatRepository: PendingChatRecording {
    private let store: any PendingChatStore
    private var cached: [PendingChat] = []
    private var currentIdentityID: IdentityID?
    private var continuations: [UUID: AsyncStream<[PendingChat]>.Continuation] = [:]

    public init(store: any PendingChatStore, currentIdentityID: IdentityID? = nil) {
        self.store = store
        self.currentIdentityID = currentIdentityID
    }

    // MARK: - PendingChatRecording

    @discardableResult
    public func record(_ chat: PendingChat) async -> PendingChatWriteOutcome {
        let outcome = await store.insert(chat)
        // A second offer for a chat already waiting is a *re-invite*:
        // the founder minted a fresh intro key, and "Generate new link"
        // revoked the one this row holds. Keeping the old key would
        // seal the request to a dead address — reported as sent, never
        // heard, waiting forever. The status is untouched: what the
        // person asked for hasn't changed, only where to ask.
        if outcome == .alreadyPresent { await refreshOffer(chat) }
        // No refresh on `.alreadyPresent`: nothing changed, and a replayed
        // offer arriving on every relay reconnect would otherwise re-yield
        // the whole list to every subscriber for no reason.
        if outcome == .inserted { await refreshFromStore() }
        return outcome
    }

    // MARK: - Mutations

    /// The join request is out. Called after `JoinRequestSender` reports
    /// `.sent`, so the row only claims to be waiting on the founder once
    /// something actually left the device.
    public func markRequested(id: String) async {
        await store.setStatus(id: id, status: .requested)
        await refreshFromStore()
    }

    public func markFailed(id: String, failure: PendingChat.SendFailure) async {
        await store.setStatus(id: id, status: .failed(failure))
        await refreshFromStore()
    }

    /// Point an existing row at a newer offer's reply channel, leaving
    /// its status alone — see `PendingChatStore.refreshOffer`.
    public func refreshOffer(_ chat: PendingChat) async {
        await store.refreshOffer(
            id: chat.id,
            introPublicKey: chat.introPublicKey,
            groupName: chat.groupName,
            inviterAlias: chat.inviterAlias,
            invitationMessage: chat.invitationMessage
        )
        await refreshFromStore()
    }

    /// Remember the name this device asked under, so a re-send
    /// introduces the same person.
    public func attachJoinerLabel(id: String, label: String) async {
        await store.setJoinerLabel(id: id, label: label)
        await refreshFromStore()
    }

    /// Drop a row the user swiped away. Local only — no NACK to the
    /// founder, whose outstanding intro key simply goes unused.
    public func remove(id: String) async {
        await store.delete(id: id)
        await refreshFromStore()
    }

    /// Drop every pending row whose group now exists locally: the
    /// founder approved, the invitation materialized the group, and the
    /// waiting room has become the chat itself.
    ///
    /// Takes `(group, owner)` pairs, not group ids. Two identities on
    /// one device can be waiting on the same group, and the snapshot
    /// that triggers this is filtered to whichever one is selected — so
    /// matching on the group alone deleted the other identity's row the
    /// moment this one got in.
    public func consumeForMaterialized(_ groups: [(groupIDHex: String, owner: IdentityID)]) async {
        guard !groups.isEmpty else { return }
        // An empty cache at launch is ambiguous — no pending chats, or
        // no read yet — and the group watcher can emit before the
        // startup `reload()` lands. Reading through settles it: without
        // this, a row whose group materialized while the app was closed
        // survives the one emission that would have swept it and then
        // sits in the list until some unrelated group mutation.
        if cached.isEmpty { await refreshFromStore() }
        let landed = Set(groups.map { "\($0.groupIDHex):\($0.owner.rawValue.uuidString)" })
        let matched = Set(cached.map(\.id)).intersection(landed)
        guard !matched.isEmpty else { return }
        await store.deleteForIDs(matched)
        await refreshFromStore()
    }

    /// Cascade for the identity-removal flow.
    public func removeForOwner(_ id: IdentityID) async {
        await store.deleteOwner(id.rawValue.uuidString)
        await refreshFromStore()
    }

    // MARK: - Identity selection

    public func setCurrentIdentity(_ id: IdentityID?) {
        guard currentIdentityID != id else { return }
        currentIdentityID = id
        publishFiltered()
    }

    /// Force a read from the backing store. Used at launch; mutators
    /// call it themselves.
    public func reload() async {
        await refreshFromStore()
    }

    /// One-shot read across **all** identities, for the deeplink path:
    /// it has to know whether this device already has a row for the
    /// group before it creates a second one.
    public func currentChats() async -> [PendingChat] {
        if cached.isEmpty { await refreshFromStore() }
        return cached
    }

    // MARK: - Subscriptions

    public nonisolated var snapshots: AsyncStream<[PendingChat]> {
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
        continuation: AsyncStream<[PendingChat]>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(filtered())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func refreshFromStore() async {
        cached = await store.list()
        publishFiltered()
    }

    private func filtered() -> [PendingChat] {
        guard let currentIdentityID else { return [] }
        return cached.filter { $0.ownerIdentityID == currentIdentityID }
    }

    private func publishFiltered() {
        let snapshot = filtered()
        for cont in continuations.values { cont.yield(snapshot) }
    }
}
