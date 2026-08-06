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

    /// Drop a handled request and tombstone its id. Conformers MUST
    /// tombstone durably: cold starts replay the inbox too.
    func consume(id: String) async

    /// Drop tombstones for links that no longer exist, so the durable
    /// set stays bounded by the live invites.
    func pruneTombstones(keeping livePublicKeys: Set<Data>) async

    /// Snapshot read used by tests + bootstrap reads. UI prefers
    /// the stream.
    func current() async -> [IntroRequest]
}

/// Process-lifetime conformer. Used by tests, and as the launch fallback
/// when the SwiftData container can't be opened — a storage failure
/// degrades to "requests don't survive a relaunch" rather than blocking
/// launch outright.
public actor InMemoryIntroRequestStore: IntroRequestStore {

    private var pending: [IntroRequest] = []
    /// Event ids already acted on, mirrored from `handledLog` so the
    /// hot `record` path doesn't hit storage per inbound.
    private var consumed: Set<String>
    /// Durable half of the tombstone. Process-lifetime alone would let
    /// every handled request re-decode on the next cold start.
    private let handledLog: any HandledIntroRequestLog
    private var continuations: [UUID: AsyncStream<[IntroRequest]>.Continuation] = [:]

    public init(handledLog: any HandledIntroRequestLog = InMemoryHandledIntroRequestLog()) {
        self.handledLog = handledLog
        self.consumed = handledLog.handledIDs()
    }

    @discardableResult
    public func record(_ request: IntroRequest) async -> Bool {
        if consumed.contains(request.id) { return false }
        if pending.contains(where: { $0.id == request.id }) { return false }
        pending.append(request)
        publish()
        return true
    }

    public func consume(id: String) async {
        // Unconditional, so a tombstone can be laid ahead of a replay
        // that hasn't landed yet.
        consumed.insert(id)
        // Attribute to the link it arrived on so `pruneTombstones` can
        // drop it when that link is retired.
        if let raw = pending.first(where: { $0.id == id }) {
            handledLog.record(id: id, introPublicKey: raw.targetIntroPublicKey)
        }
        let before = pending.count
        pending.removeAll { $0.id == id }
        if pending.count != before { publish() }
    }

    public func pruneTombstones(keeping livePublicKeys: Set<Data>) async {
        handledLog.prune(keeping: livePublicKeys)
        consumed = handledLog.handledIDs()
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
