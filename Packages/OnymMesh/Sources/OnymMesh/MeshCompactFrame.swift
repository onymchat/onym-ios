import Foundation

/// The frame that fits a 31-byte legacy advertisement — the one every
/// iPhone reliably hands to apps (spec §4b).
///
/// It rides in Manufacturer Specific Data under company ID `0xFFFF`
/// (the SIG's reserved test ID, until Onym has its own):
///
/// ```
/// offset  size  field
///      0     1  kind        0xC1
///      1     1  epochLow    epoch & 0xFF
///      2     3  tag         for that epoch
///      5     2  envelopeID  UInt16 big-endian, scoped by tag + epoch
///      7     1  index       0-based
///      8     1  count       1...255, index < count
///      9     …  chunk       1...maxChunk bytes
/// ```
///
/// The 18-byte v1 header doesn't fit, so this one drops what a receiver
/// can work out: the epoch's low byte is unambiguous inside the 24-hour
/// window (98 epochs < 256), and the envelope ID only has to tell apart
/// envelopes that share a tag and an epoch — one sender, one recipient,
/// one quarter hour.
public struct MeshCompactFrame: Equatable, Sendable {
    public static let kind: UInt8 = 0xC1
    public static let headerSize = 9
    /// Bluetooth SIG company ID for internal testing. Little-endian on
    /// the air, as every company ID is.
    public static let companyID: UInt16 = 0xFFFF
    /// What a broadcaster puts in each frame. 31 bytes, less the AD
    /// header and company ID (4), less a Flags AD (3) some Android
    /// stacks add even when not connectable, less this header (9).
    public static let maxChunk = 15

    public let epochLow: UInt8
    public let tag: MeshTag
    public let envelopeID: UInt16
    public let index: UInt8
    public let count: UInt8
    public let chunk: Data

    public init(epochLow: UInt8, tag: MeshTag, envelopeID: UInt16, index: UInt8, count: UInt8, chunk: Data) {
        self.epochLow = epochLow
        self.tag = tag
        self.envelopeID = envelopeID
        self.index = index
        self.count = count
        self.chunk = chunk
    }

    /// From the payload after the company ID. Nil for anything that
    /// isn't a well-formed compact frame.
    public init?(bytes: Data) {
        let b = [UInt8](bytes)
        guard b.count > Self.headerSize, b[0] == Self.kind else { return nil }
        guard let tag = MeshTag(bytes: Data(b[2..<5])) else { return nil }
        let index = b[7], count = b[8]
        guard count >= 1, index < count else { return nil }
        self.init(
            epochLow: b[1], tag: tag,
            envelopeID: UInt16(b[5]) << 8 | UInt16(b[6]),
            index: index, count: count, chunk: Data(b[Self.headerSize...])
        )
    }

    public var bytes: Data {
        var out = Data([Self.kind, epochLow])
        out.append(tag.bytes)
        out.append(contentsOf: [UInt8(envelopeID >> 8), UInt8(envelopeID & 0xFF), index, count])
        out.append(chunk)
        return out
    }

    /// The full epoch this frame's low byte names, if it falls in the
    /// window a receiver accepts (`oldest...current + 1`).
    public static func resolveEpoch(low: UInt8, oldest: UInt32, current: UInt32) -> UInt32? {
        var e = current &+ 1
        while e >= oldest {
            if UInt8(e & 0xFF) == low { return e }
            if e == 0 { break }
            e -= 1
        }
        return nil
    }

    /// As a v1 frame, so reassembly and delivery are shared. Its
    /// envelope ID folds in the epoch and tag, which is what scopes a
    /// compact ID.
    public func meshFrame(epoch: UInt32) -> MeshFrame {
        let tagBits = tag.bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let key = UInt64(epoch & 0xFF_FFFF) << 40 | tagBits << 16 | UInt64(envelopeID)
        return MeshFrame(epoch: epoch, tag: tag, envelopeID: key, index: index, count: count, chunk: chunk)
    }

    public static func fragment(
        envelope: Data,
        tag: MeshTag,
        epoch: UInt32,
        envelopeID: UInt16,
        maxChunk: Int = MeshCompactFrame.maxChunk
    ) -> [MeshCompactFrame]? {
        guard maxChunk > 0, !envelope.isEmpty else { return nil }
        let count = (envelope.count + maxChunk - 1) / maxChunk
        guard count <= Int(UInt8.max) else { return nil }
        return (0..<count).map { i in
            let start = envelope.startIndex + i * maxChunk
            let end = min(start + maxChunk, envelope.endIndex)
            return MeshCompactFrame(
                epochLow: UInt8(epoch & 0xFF), tag: tag, envelopeID: envelopeID,
                index: UInt8(i), count: UInt8(count), chunk: envelope[start..<end]
            )
        }
    }
}
