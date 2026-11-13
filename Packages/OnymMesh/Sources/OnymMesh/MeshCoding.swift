import Foundation

/// GF(2⁸) with the polynomial x⁸+x⁴+x³+x²+1 (0x11D), generator 2 —
/// the field the coded frames' combinations are taken in (spec §4c).
enum GF256 {
    static let (exp, log): ([UInt8], [UInt8]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [UInt8](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = UInt8(i)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    @inline(__always) static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[Int(log[Int(a)]) + Int(log[Int(b)])]
    }

    @inline(__always) static func inv(_ a: UInt8) -> UInt8 {
        exp[255 - Int(log[Int(a)])]
    }
}

/// The erasure code behind coded frames (spec §4c): an envelope is split
/// into K symbols, frames 0…K−1 carry them as they are, and every later
/// index carries a GF(256) combination of all K. A listener rebuilds the
/// envelope from any K independent frames — whichever ones it happened to
/// catch, in any order — instead of waiting for every specific fragment.
public enum MeshFountain {
    /// Bytes of envelope per frame: 31 for a legacy advertisement, less
    /// the 16-bit service UUID list a backgrounded iPhone's scan filter
    /// matches (4), less the Service Data header and UUID (4), less the
    /// coded frame's header (10). Non-connectable advertisements carry no
    /// Flags, so nothing else competes for the space.
    public static let symbolSize = 13
    /// 255 symbols, less the 2-byte length prefix.
    public static let maxEnvelopeSize = 255 * symbolSize - 2

    /// A repair frame's coefficients: a Cauchy row, `1 / (x ⊕ m)` for
    /// symbol `m`, with `x = k + (index − k) mod (256 − k)`. Source symbols
    /// sit at `0…k−1` and repair rows at `k…255`, disjoint, so any k
    /// distinct frames — sources and repairs mixed — are independent:
    /// none is ever wasted. Indices past 255 repeat earlier rows.
    public static func coefficients(index: UInt16, k: Int) -> [UInt8] {
        let x = UInt8(k + (Int(index) - k) % (256 - k))
        return (0..<k).map { GF256.inv(x ^ UInt8($0)) }
    }

    /// Produces any frame's symbol for one envelope.
    public struct Encoder: Sendable {
        public let k: Int
        public let envelopeID: UInt16
        private let symbols: [[UInt8]]

        /// Nil for an empty envelope or one too large for 255 symbols.
        public init?(envelope: Data, envelopeID: UInt16) {
            guard !envelope.isEmpty, envelope.count <= MeshFountain.maxEnvelopeSize else { return nil }
            var buffer = [UInt8(envelope.count >> 8), UInt8(envelope.count & 0xFF)] + envelope
            let k = (buffer.count + symbolSize - 1) / symbolSize
            buffer += [UInt8](repeating: 0, count: k * symbolSize - buffer.count)
            self.k = k
            self.envelopeID = envelopeID
            self.symbols = (0..<k).map { Array(buffer[$0 * symbolSize ..< ($0 + 1) * symbolSize]) }
        }

        public func symbol(index: UInt16) -> Data {
            if Int(index) < k { return Data(symbols[Int(index)]) }
            let coefficients = MeshFountain.coefficients(index: index, k: k)
            var out = [UInt8](repeating: 0, count: symbolSize)
            for (m, c) in coefficients.enumerated() {
                for j in 0..<symbolSize { out[j] ^= GF256.mul(c, symbols[m][j]) }
            }
            return Data(out)
        }
    }

    /// Rebuilds one envelope from frames arriving in any order: online
    /// Gaussian elimination, kept in reduced row-echelon form, so each new
    /// frame either adds a pivot or is recognised as redundant at once.
    public struct Decoder: Sendable {
        public let k: Int
        public let envelopeID: UInt16
        private var rows: [Int: (coefficients: [UInt8], data: [UInt8])] = [:]

        public init(k: Int, envelopeID: UInt16) {
            self.k = k
            self.envelopeID = envelopeID
        }

        /// Independent frames held so far; complete at `k`.
        public var rank: Int { rows.count }

        /// The envelope once `k` independent frames are in; nil until then.
        public mutating func add(index: UInt16, symbol: Data) -> Data? {
            guard symbol.count == symbolSize, rows.count < k else { return nil }
            var v: [UInt8]
            if Int(index) < k {
                v = [UInt8](repeating: 0, count: k)
                v[Int(index)] = 1
            } else {
                v = MeshFountain.coefficients(index: index, k: k)
            }
            var d = [UInt8](symbol)
            for (pivot, row) in rows where v[pivot] != 0 {
                let f = v[pivot]
                for m in 0..<k { v[m] ^= GF256.mul(f, row.coefficients[m]) }
                for j in 0..<symbolSize { d[j] ^= GF256.mul(f, row.data[j]) }
            }
            guard let column = v.firstIndex(where: { $0 != 0 }) else { return nil }
            let scale = GF256.inv(v[column])
            for m in 0..<k { v[m] = GF256.mul(scale, v[m]) }
            for j in 0..<symbolSize { d[j] = GF256.mul(scale, d[j]) }
            for (pivot, row) in rows where row.coefficients[column] != 0 {
                let f = row.coefficients[column]
                var c = row.coefficients, rd = row.data
                for m in 0..<k { c[m] ^= GF256.mul(f, v[m]) }
                for j in 0..<symbolSize { rd[j] ^= GF256.mul(f, d[j]) }
                rows[pivot] = (c, rd)
            }
            rows[column] = (v, d)
            guard rows.count == k else { return nil }

            var buffer: [UInt8] = []
            buffer.reserveCapacity(k * symbolSize)
            for i in 0..<k { buffer += rows[i]!.data }
            let length = Int(buffer[0]) << 8 | Int(buffer[1])
            guard length > 0, length <= buffer.count - 2 else { return nil }
            return Data(buffer[2 ..< 2 + length])
        }
    }
}

/// A coded frame (kind `0xC2`, spec §4c), in Service Data under the
/// mesh's 16-bit UUID (`MeshService.codedUUID`):
///
/// ```
/// offset  size  field
///      0     1  kind        0xC2
///      1     1  epochLow    epoch & 0xFF
///      2     3  tag         for that epoch
///      5     2  envelopeID  UInt16 big-endian
///      7     1  k           source symbols, 1...255
///      8     2  index       UInt16 big-endian; < k source, ≥ k repair
///     10    13  symbol
/// ```
public struct MeshCodedFrame: Equatable, Sendable {
    public static let kind: UInt8 = 0xC2
    public static let headerSize = 10

    public let epochLow: UInt8
    public let tag: MeshTag
    public let envelopeID: UInt16
    public let k: UInt8
    public let index: UInt16
    public let symbol: Data

    public init(epochLow: UInt8, tag: MeshTag, envelopeID: UInt16, k: UInt8, index: UInt16, symbol: Data) {
        self.epochLow = epochLow
        self.tag = tag
        self.envelopeID = envelopeID
        self.k = k
        self.index = index
        self.symbol = symbol
    }

    public init?(bytes: Data) {
        let b = [UInt8](bytes)
        guard b.count == Self.headerSize + MeshFountain.symbolSize, b[0] == Self.kind, b[7] >= 1,
              let tag = MeshTag(bytes: Data(b[2..<5]))
        else { return nil }
        self.init(
            epochLow: b[1], tag: tag,
            envelopeID: UInt16(b[5]) << 8 | UInt16(b[6]),
            k: b[7],
            index: UInt16(b[8]) << 8 | UInt16(b[9]),
            symbol: Data(b[Self.headerSize...])
        )
    }

    public var bytes: Data {
        var out = Data([Self.kind, epochLow])
        out.append(tag.bytes)
        out.append(contentsOf: [UInt8(envelopeID >> 8), UInt8(envelopeID & 0xFF), k, UInt8(index >> 8), UInt8(index & 0xFF)])
        out.append(symbol)
        return out
    }

    /// What scopes a 16-bit envelope ID: the epoch and tag, as for compact frames.
    public func key(epoch: UInt32) -> UInt64 {
        let tagBits = tag.bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return UInt64(epoch & 0xFF_FFFF) << 40 | tagBits << 16 | UInt64(envelopeID)
    }
}
