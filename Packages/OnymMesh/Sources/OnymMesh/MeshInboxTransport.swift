import Foundation
import OnymTransport

/// One (local inbox, peer) pair the mesh can deliver for: frames whose
/// tag derives from `pairKey` belong to `inbox`.
public struct MeshContact: Hashable, Sendable {
    public let inbox: TransportInboxID
    public let pairKey: Data

    public init(inbox: TransportInboxID, pairKey: Data) {
        self.inbox = inbox
        self.pairKey = pairKey
    }
}

/// Raw frames off the radio. `BLEMeshScanner` is the real one; tests
/// feed bytes directly.
public protocol MeshFrameSource: Sendable {
    func frames() -> AsyncStream<Data>
}

/// The Bluetooth mesh as an `InboxTransport` — receive only.
///
/// It listens and never transmits: `send` always throws, so it can't be
/// put on a send path by mistake, and nothing it does tells a
/// broadcaster that a frame was heard or by whom. Delivered envelopes
/// are marked `.bluetooth` so the dispatcher sends no receipt for them.
///
/// Matching is local and silent. For each frame's epoch it computes the
/// tags of every contact and keeps the frame only on a match; everything
/// else is dropped unread.
public actor MeshInboxTransport: InboxTransport {
    /// How far back a broadcaster may still be looping an envelope.
    public static let retention: TimeInterval = 24 * 60 * 60

    private let source: any MeshFrameSource
    private let contacts: @Sendable () async -> [MeshContact]
    private let now: @Sendable () -> Date
    private let contactsRefresh: TimeInterval

    private var reassembler = MeshReassembler()
    private var subscribers: [TransportInboxID: [UUID: AsyncStream<InboundInbox>.Continuation]] = [:]
    private var listening: Task<Void, Never>?

    private var knownContacts: [MeshContact] = []
    private var contactsLoadedAt: Date?
    /// Tags per epoch, computed on first use and dropped when contacts
    /// change. A day of epochs × a few hundred contacts is small.
    private var tagCache: [UInt32: [MeshTag: Set<TransportInboxID>]] = [:]

    public init(
        source: any MeshFrameSource,
        contacts: @escaping @Sendable () async -> [MeshContact],
        contactsRefresh: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.contacts = contacts
        self.contactsRefresh = contactsRefresh
        self.now = now
    }

    // MARK: - InboxTransport

    /// Starts listening. Endpoints mean nothing to a radio.
    public func connect(to endpoints: [TransportEndpoint]) async {
        guard listening == nil else { return }
        let stream = source.frames()
        listening = Task { [weak self] in
            for await bytes in stream {
                if Task.isCancelled { break }
                await self?.receive(bytes)
            }
        }
    }

    public func disconnect() async {
        listening?.cancel()
        listening = nil
    }

    public func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        throw TransportError.notConnected
    }

    public nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        let (stream, continuation) = AsyncStream<InboundInbox>.makeStream()
        let id = UUID()
        Task { await self.add(continuation, id: id, inbox: inbox) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id: id, inbox: inbox) }
        }
        return stream
    }

    public func unsubscribe(inbox: TransportInboxID) async {
        subscribers.removeValue(forKey: inbox)?.values.forEach { $0.finish() }
    }

    // MARK: - Receiving

    /// One frame's bytes: decode, check the epoch is plausible, match the
    /// tag, reassemble, deliver. Internal so tests can drive it directly.
    func receive(_ bytes: Data) async {
        let date = now()
        let current = MeshEpoch.number(at: date)
        let oldest = MeshEpoch.number(at: date.addingTimeInterval(-Self.retention))
        // Two shapes on the air, told apart by their first byte: v1
        // frames from extended advertising, compact ones from legacy.
        let decoded: MeshFrame?
        switch bytes.first {
        case MeshFrame.version:
            decoded = MeshFrame(bytes: bytes)
        case MeshCompactFrame.kind:
            decoded = MeshCompactFrame(bytes: bytes).flatMap { compact in
                MeshCompactFrame.resolveEpoch(low: compact.epochLow, oldest: oldest, current: current)
                    .map { compact.meshFrame(epoch: $0) }
            }
        default:
            decoded = nil
        }
        guard let frame = decoded else { return }
        guard frame.epoch >= oldest, frame.epoch <= current &+ 1 else { return }

        await refreshContactsIfStale(at: date)
        guard let inboxes = tags(for: frame.epoch)[frame.tag], !inboxes.isEmpty else { return }
        guard let envelope = reassembler.add(frame, at: date) else { return }

        let messageID = "ble:" + String(format: "%016llx", frame.envelopeID)
        for inbox in inboxes {
            let message = InboundInbox(
                inbox: inbox, payload: envelope, receivedAt: date,
                messageID: messageID, delivery: .bluetooth
            )
            subscribers[inbox]?.values.forEach { $0.yield(message) }
        }
    }

    private func refreshContactsIfStale(at date: Date) async {
        if let loaded = contactsLoadedAt, date.timeIntervalSince(loaded) < contactsRefresh { return }
        let fresh = await contacts()
        contactsLoadedAt = date
        if fresh != knownContacts {
            knownContacts = fresh
            tagCache = [:]
        }
    }

    private func tags(for epoch: UInt32) -> [MeshTag: Set<TransportInboxID>] {
        if let cached = tagCache[epoch] { return cached }
        var table: [MeshTag: Set<TransportInboxID>] = [:]
        for contact in knownContacts {
            table[MeshTag.derive(pairKey: contact.pairKey, epoch: epoch), default: []].insert(contact.inbox)
        }
        // Keep a day's worth plus slack; evict the oldest beyond that.
        if tagCache.count > 100, let oldest = tagCache.keys.min() {
            tagCache[oldest] = nil
        }
        tagCache[epoch] = table
        return table
    }

    private func add(_ continuation: AsyncStream<InboundInbox>.Continuation, id: UUID, inbox: TransportInboxID) {
        subscribers[inbox, default: [:]][id] = continuation
    }

    private func remove(id: UUID, inbox: TransportInboxID) {
        subscribers[inbox]?[id] = nil
        if subscribers[inbox]?.isEmpty == true { subscribers[inbox] = nil }
    }
}
