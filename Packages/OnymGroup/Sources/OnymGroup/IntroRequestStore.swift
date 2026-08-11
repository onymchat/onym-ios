import Foundation

/// Sink for inbound intro requests.
///
/// Two conformers: `SwiftDataIntroRequestStore` (production — durable,
/// with a retention sweep) and `InMemoryIntroRequestStore` (tests, and
/// the launch fallback when the on-disk container can't be opened).
///
/// Durability became a requirement when the approval surface moved from
/// a modal into the chat thread: a request that vanished on force-quit
/// reads as a message the app lost, while the joiner is still sitting on
/// "Waiting for the host to approve…".
///
/// Mirrors the shape of `IncomingInvitationsRepository`.
public protocol IntroRequestStore: Sendable {
    /// Hot stream of pending requests. Sorted newest-first by
    /// `receivedAt`. UI subscribes here.
    nonisolated var requests: AsyncStream<[IntroRequest]> { get }

    /// Append a fresh request. Dedup on `IntroRequest.id`; returns
    /// `true` on insert, `false` if the id was already present.
    @discardableResult
    func record(_ request: IntroRequest) async -> Bool

    /// Drop a request after the user has acted on it (Approve or
    /// Decline) so it stops cluttering the surface.
    func consume(id: String) async

    /// Snapshot read used by tests + bootstrap reads. UI prefers
    /// the stream.
    func current() async -> [IntroRequest]
}

/// Process-lifetime conformer. Used by tests, and as the launch fallback
/// when the SwiftData container can't be opened — a storage failure
/// degrades to "requests don't survive a relaunch" rather than blocking
/// launch outright.
public actor InMemoryIntroRequestStore: IntroRequestStore {

    public init() {}

    private var pending: [IntroRequest] = []
    private var continuations: [UUID: AsyncStream<[IntroRequest]>.Continuation] = [:]

    @discardableResult
    public func record(_ request: IntroRequest) async -> Bool {
        if pending.contains(where: { $0.id == request.id }) { return false }
        pending.append(request)
        publish()
        return true
    }

    public func consume(id: String) async {
        let before = pending.count
        pending.removeAll { $0.id == id }
        if pending.count != before { publish() }
    }

    public func current() async -> [IntroRequest] {
        pending.sorted { $0.receivedAt > $1.receivedAt }
    }

    public nonisolated var requests: AsyncStream<[IntroRequest]> {
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
