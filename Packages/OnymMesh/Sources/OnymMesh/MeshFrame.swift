import Foundation

/// One broadcast: a fragment of a sealed envelope, as it sits in the
/// mesh service's Service Data (spec: `docs/mesh-ble-v1.md`).
///
/// ```
/// offset  size  field
///      0     1  version      (1)
///      1     4  epoch        UInt32 big-endian, MeshEpoch.number
///      5     3  tag          MeshTag for that epoch
///      8     8  envelopeID   random per envelope, groups its fragments
///     16     1  index        0-based
///     17     1  count        1...255, index < count
///     18     …  chunk        ≥ 1 byte
/// ```
///
/// Every fragment repeats the tag, so a receiver drops fragments that
/// aren't for it without buffering a byte of them. Nothing in the frame
/// identifies the sender: who sent it is inside the sealed envelope.
public struct MeshFrame: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let headerSize = 18
    /// The largest envelope the mesh carries. Larger ones stay on Nostr.
    public static let maxEnvelopeSize = 16 * 1024

    public let epoch: UInt32
    public let tag: MeshTag
    public let envelopeID: UInt64
    public let index: UInt8
    public let count: UInt8
    public let chunk: Data

    public init(epoch: UInt32, tag: MeshTag, envelopeID: UInt64, index: UInt8, count: UInt8, chunk: Data) {
        self.epoch = epoch
        self.tag = tag
        self.envelopeID = envelopeID
        self.index = index
        self.count = count
        self.chunk = chunk
    }

    /// Nil for anything that isn't a well-formed v1 frame — a radio is
    /// an untrusted input, so malformed bytes are dropped, never thrown.
    public init?(bytes: Data) {
        let b = [UInt8](bytes)
        guard b.count > Self.headerSize, b[0] == Self.version else { return nil }
        let epoch = b[1..<5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let tag = MeshTag(bytes: Data(b[5..<8])) else { return nil }
        let envelopeID = b[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let index = b[16], count = b[17]
        guard count >= 1, index < count else { return nil }
        self.init(
            epoch: epoch, tag: tag, envelopeID: envelopeID,
            index: index, count: count, chunk: Data(b[Self.headerSize...])
        )
    }

    public var bytes: Data {
        var out = Data([Self.version])
        out.append(contentsOf: withUnsafeBytes(of: epoch.bigEndian) { Array($0) })
        out.append(tag.bytes)
        out.append(contentsOf: withUnsafeBytes(of: envelopeID.bigEndian) { Array($0) })
        out.append(contentsOf: [index, count])
        out.append(chunk)
        return out
    }

    /// Split an envelope into frames of at most `maxFrameSize` bytes.
    /// What a broadcaster does; here for the spec's test vectors and the
    /// round-trip tests, since iOS itself never broadcasts.
    public static func fragment(
        envelope: Data,
        tag: MeshTag,
        epoch: UInt32,
        envelopeID: UInt64,
        maxFrameSize: Int
    ) -> [MeshFrame]? {
        let chunkSize = maxFrameSize - headerSize
        guard chunkSize > 0, !envelope.isEmpty, envelope.count <= maxEnvelopeSize else { return nil }
        let count = (envelope.count + chunkSize - 1) / chunkSize
        guard count <= Int(UInt8.max) else { return nil }
        return (0..<count).map { i in
            let start = envelope.startIndex + i * chunkSize
            let end = min(start + chunkSize, envelope.endIndex)
            return MeshFrame(
                epoch: epoch, tag: tag, envelopeID: envelopeID,
                index: UInt8(i), count: UInt8(count), chunk: envelope[start..<end]
            )
        }
    }
}

/// Puts envelopes back together from fragments that arrive in any
/// order, any number of times, interleaved with other envelopes.
///
/// Broadcasters loop, so a missed fragment comes round again — which is
/// also why every limit here is a cap rather than an error: memory and
/// time are bounded however hostile the airwaves are, and an envelope
/// that can't be completed is simply forgotten.
public struct MeshReassembler: Sendable {
    /// How long a partial envelope's progress is kept. Generous: a
    /// broadcaster loops for a day, and a listener that only catches some
    /// advertisements per lap needs many laps — dropping progress after a
    /// few minutes could keep a long message from ever completing.
    public var timeout: TimeInterval = 30 * 60
    public var maxPending = 64
    /// Envelopes already delivered, kept so a looping broadcaster doesn't
    /// hand the same message to the dispatcher every lap.
    public var deliveredMemory: TimeInterval = 30 * 60

    private struct Pending {
        var count: UInt8
        var chunks: [UInt8: Data]
        var bytes: Int
        var firstSeen: Date
    }

    private var pending: [UInt64: Pending] = [:]
    private var delivered: [UInt64: Date] = [:]

    public init() {}

    /// The whole envelope once its last missing fragment arrives;
    /// nil until then, and nil for fragments of anything already
    /// delivered or inconsistent with what came before.
    /// Fragments held so far for an envelope still being assembled.
    public func progress(of envelopeID: UInt64) -> (have: Int, count: Int)? {
        pending[envelopeID].map { ($0.chunks.count, Int($0.count)) }
    }

    public mutating func add(_ frame: MeshFrame, at now: Date) -> Data? {
        expire(now: now)
        if delivered[frame.envelopeID] != nil { return nil }

        var entry = pending[frame.envelopeID] ?? Pending(count: frame.count, chunks: [:], bytes: 0, firstSeen: now)
        // A fragment that disagrees about the envelope's size is noise
        // (or an ID collision); the first one to arrive sets the shape.
        guard entry.count == frame.count else { return nil }
        if entry.chunks[frame.index] == nil {
            guard entry.bytes + frame.chunk.count <= MeshFrame.maxEnvelopeSize else {
                pending[frame.envelopeID] = nil
                return nil
            }
            entry.chunks[frame.index] = frame.chunk
            entry.bytes += frame.chunk.count
        }

        guard entry.chunks.count == Int(entry.count) else {
            if pending[frame.envelopeID] == nil, pending.count >= maxPending {
                evictOldest()
            }
            pending[frame.envelopeID] = entry
            return nil
        }

        pending[frame.envelopeID] = nil
        delivered[frame.envelopeID] = now
        var envelope = Data(capacity: entry.bytes)
        for i in 0..<entry.count { envelope.append(entry.chunks[i]!) }
        return envelope
    }

    private mutating func expire(now: Date) {
        pending = pending.filter { now.timeIntervalSince($0.value.firstSeen) < timeout }
        delivered = delivered.filter { now.timeIntervalSince($0.value) < deliveredMemory }
    }

    private mutating func evictOldest() {
        guard let oldest = pending.min(by: { $0.value.firstSeen < $1.value.firstSeen }) else { return }
        pending[oldest.key] = nil
    }
}
