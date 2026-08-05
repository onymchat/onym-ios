import Foundation

/// In-memory sink for inbound intro requests. Process-lifetime —
/// the request approval flow (PR-4) is interactive; if the user
/// doesn't act before the process dies, the joiner re-shares.
///
/// Mirrors the shape of `IncomingInvitationsRepository` — identical
/// posture for the V1 receive-side (interactive UI consumes the
/// stream; persistence lands later if we need durability across
/// restarts).
protocol IntroRequestStore: Sendable {
    /// Hot stream of pending requests. Sorted newest-first by
    /// `receivedAt`. UI subscribes here.
    nonisolated var requests: AsyncStream<[IntroRequest]> { get }

    /// Append a fresh request. Dedup on `IntroRequest.id`; returns
    /// `true` on insert, `false` if the id was already present.
    @discardableResult
    func record(_ request: IntroRequest) async -> Bool

    /// Drop a request after the user has acted on it (Approve or
    /// Decline) so it stops cluttering the surface, and remember its
    /// id so a replay can't resurrect it.
    ///
    /// Conformers MUST tombstone. `NostrInboxTransport`'s REQ carries
    /// no `since` and no `limit`, so every relay reconnect re-delivers
    /// the intro inbox in full. Dropping the row from `pending` alone
    /// means the next replay re-records it and the user sees a request
    /// they already handled.
    func consume(id: String) async

    /// Snapshot read used by tests + bootstrap reads. UI prefers
    /// the stream.
    func current() async -> [IntroRequest]
}

actor InMemoryIntroRequestStore: IntroRequestStore {
    private var pending: [IntroRequest] = []
    /// Event ids the user already acted on. Process-lifetime, matching
    /// `pending`: a relaunch legitimately re-surfaces anything the user
    /// never got round to (the type doc's contract), but within a
    /// session an approved or declined row must stay gone.
    private var consumed: Set<String> = []
    private var continuations: [UUID: AsyncStream<[IntroRequest]>.Continuation] = [:]

    @discardableResult
    func record(_ request: IntroRequest) async -> Bool {
        if consumed.contains(request.id) { return false }
        if pending.contains(where: { $0.id == request.id }) { return false }
        pending.append(request)
        publish()
        return true
    }

    func consume(id: String) async {
        // Tombstone unconditionally, even when the id isn't pending, so
        // a tombstone can be laid ahead of a replay that hasn't landed
        // yet.
        consumed.insert(id)
        let before = pending.count
        pending.removeAll { $0.id == id }
        if pending.count != before { publish() }
    }

    func current() async -> [IntroRequest] {
        pending.sorted { $0.receivedAt > $1.receivedAt }
    }

    nonisolated var requests: AsyncStream<[IntroRequest]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(id: UUID, continuation: AsyncStream<[IntroRequest]>.Continuation) {
        continuations[id] = continuation
        continuation.yield(pending.sorted { $0.receivedAt > $1.receivedAt })
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        let snap = pending.sorted { $0.receivedAt > $1.receivedAt }
        for cont in continuations.values { cont.yield(snap) }
    }
}
