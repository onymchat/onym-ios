import Foundation
import OnymTransport
import os

/// Diagnostics for field tests (Xcode console / Console.app). Tags are
/// public: they rotate every 15 minutes and say nothing without the pair
/// key, which is never logged.
private let log = Logger(subsystem: "app.onym.mesh", category: "listener")

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
    private var unmatchedLogged: Set<String> = []
    private var lastProgress: [UInt64: Int] = [:]
    private var decoders: [UInt64: (decoder: MeshFountain.Decoder, firstSeen: Date)] = [:]
    private var codedDelivered: [UInt64: Date] = [:]

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
        // Three shapes on the air, told apart by their first byte: v1
        // frames from extended advertising; compact and coded ones from
        // legacy advertising.
        switch bytes.first {
        case MeshFrame.version:
            if let frame = MeshFrame(bytes: bytes) { await receiveFragment(frame, at: date, oldest: oldest, current: current) }
        case MeshCompactFrame.kind:
            guard let compact = MeshCompactFrame(bytes: bytes),
                  let epoch = MeshCompactFrame.resolveEpoch(low: compact.epochLow, oldest: oldest, current: current)
            else { return }
            await receiveFragment(compact.meshFrame(epoch: epoch), at: date, oldest: oldest, current: current)
        case MeshCodedFrame.kind:
            guard let coded = MeshCodedFrame(bytes: bytes),
                  let epoch = MeshCompactFrame.resolveEpoch(low: coded.epochLow, oldest: oldest, current: current)
            else { return }
            await receiveCoded(coded, epoch: epoch, at: date)
        default:
            return
        }
    }

    /// v1 and compact frames: fragments put back together in order.
    private func receiveFragment(_ frame: MeshFrame, at date: Date, oldest: UInt32, current: UInt32) async {
        guard frame.epoch >= oldest, frame.epoch <= current &+ 1 else { return }
        guard let inboxes = await match(epoch: frame.epoch, tag: frame.tag, at: date) else { return }
        let envelope = reassembler.add(frame, at: date)
        if envelope == nil, let progress = reassembler.progress(of: frame.envelopeID) {
            reportProgress(key: frame.envelopeID, have: progress.have, count: progress.count)
        }
        guard let envelope else { return }
        deliver(envelope, key: frame.envelopeID, to: inboxes, at: date)
    }

    /// Coded frames: any `k` independent ones rebuild the envelope, which
    /// arrives in binary and is turned back into the inbox's JSON.
    private func receiveCoded(_ frame: MeshCodedFrame, epoch: UInt32, at date: Date) async {
        guard let inboxes = await match(epoch: epoch, tag: frame.tag, at: date) else { return }
        let key = frame.key(epoch: epoch)
        decoders = decoders.filter { date.timeIntervalSince($0.value.firstSeen) < reassembler.timeout }
        codedDelivered = codedDelivered.filter { date.timeIntervalSince($0.value) < reassembler.deliveredMemory }
        guard codedDelivered[key] == nil else { return }

        var entry = decoders[key] ?? (MeshFountain.Decoder(k: Int(frame.k), envelopeID: frame.envelopeID), date)
        // The first frame sets the envelope's size; one that disagrees is noise.
        guard entry.decoder.k == Int(frame.k) else { return }
        let binary = entry.decoder.add(index: frame.index, symbol: frame.symbol)
        guard let binary else {
            if decoders[key] == nil, decoders.count >= reassembler.maxPending,
               let oldest = decoders.min(by: { $0.value.firstSeen < $1.value.firstSeen }) {
                decoders[oldest.key] = nil
            }
            decoders[key] = entry
            reportProgress(key: key, have: entry.decoder.rank, count: entry.decoder.k)
            return
        }
        decoders[key] = nil
        codedDelivered[key] = date
        guard let json = MeshEnvelope.json(fromBinary: binary) else {
            log.info("coded envelope \(String(format: "%016llx", key), privacy: .public) isn't a sealed envelope; dropped")
            return
        }
        deliver(json, key: key, to: inboxes, at: date)
    }

    /// The inboxes a frame is for, or nil — logged once per unknown tag.
    private func match(epoch: UInt32, tag: MeshTag, at date: Date) async -> Set<TransportInboxID>? {
        await refreshContactsIfStale(at: date)
        guard let inboxes = tags(for: epoch)[tag], !inboxes.isEmpty else {
            if unmatchedLogged.insert("\(epoch):\(tag.hex)").inserted {
                log.info("frame for someone else: epoch \(epoch, privacy: .public) tag \(tag.hex, privacy: .public) (\(self.knownContacts.count, privacy: .public) contacts)")
            }
            return nil
        }
        MeshListenerStatus.report { $0.framesForThisDevice += 1 }
        return inboxes
    }

    private func reportProgress(key: UInt64, have: Int, count: Int) {
        guard have != lastProgress[key] else { return }
        lastProgress[key] = have
        log.info("assembling \(String(format: "%016llx", key), privacy: .public): \(have, privacy: .public)/\(count, privacy: .public)")
        MeshListenerStatus.report { $0.assembling = (have, count) }
    }

    private func deliver(_ envelope: Data, key: UInt64, to inboxes: Set<TransportInboxID>, at date: Date) {
        log.info("delivered \(String(format: "%016llx", key), privacy: .public): \(envelope.count, privacy: .public) bytes")
        MeshListenerStatus.report {
            $0.assembling = nil
            $0.envelopesDelivered += 1
        }
        let messageID = "ble:" + String(format: "%016llx", key)
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
            let epoch = MeshEpoch.number(at: date)
            let expected = fresh.map { MeshTag.derive(pairKey: $0.pairKey, epoch: epoch).hex }.joined(separator: " ")
            log.info("contacts: \(fresh.count, privacy: .public); epoch \(epoch, privacy: .public) tags \(expected, privacy: .public)")
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
