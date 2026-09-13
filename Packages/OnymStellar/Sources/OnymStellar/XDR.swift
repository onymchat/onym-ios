import Foundation

/// XDR (RFC 4506) primitives, which is the encoding every Stellar
/// transaction is expressed in.
///
/// Five rules carry the whole format, and all five are load-bearing here:
///
///  - **Everything is big-endian.** Both integer widths, every length
///    prefix, every enum discriminant.
///  - **Everything is padded to a multiple of four bytes.** Fixed opaque,
///    variable opaque, and strings all pad with zeros; the padding is not
///    counted in the length prefix.
///  - **Enums and union discriminants are `int32`**, not the smallest
///    type that fits.
///  - **Optionals are a `uint32` 1/0 followed by the value when present.**
///    There is no other "absent" encoding, so an optional field that is
///    nil still costs four bytes.
///  - **Variable-length data carries a `uint32` count first**, then the
///    elements, then padding.
///
/// Written by hand rather than taken from a Stellar SDK — see
/// `StellarStrKey`'s note for the same reasoning. The cost of that
/// choice is paid in `Tests/…/StellarXDRFixtureTests`, which pins these
/// bytes against envelopes produced by an independent implementation.
public struct XDRWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    public mutating func writeUInt32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeInt64(_ value: Int64) {
        writeUInt64(UInt64(bitPattern: value))
    }

    public mutating func writeUInt64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func writeBool(_ value: Bool) {
        writeInt32(value ? 1 : 0)
    }

    /// Fixed-length opaque: the bytes, then zero padding to the next
    /// multiple of four. No length prefix — the width is known from the
    /// schema, which is why this and `writeVariableOpaque` are separate
    /// calls rather than one function with a flag.
    public mutating func writeFixedOpaque(_ bytes: Data) {
        data.append(bytes)
        writePadding(for: bytes.count)
    }

    public mutating func writeVariableOpaque(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        writeFixedOpaque(bytes)
    }

    /// XDR strings are variable opaque over UTF-8 bytes. The `<n>` bound
    /// in the schema is a *byte* bound, so callers that have a character
    /// limit must convert before checking.
    public mutating func writeString(_ value: String) {
        writeVariableOpaque(Data(value.utf8))
    }

    /// `T*` — presence flag then value. The closure runs only when
    /// `value` is non-nil, so an absent optional writes exactly four
    /// zero bytes.
    public mutating func writeOptional<T>(_ value: T?, _ body: (inout XDRWriter, T) -> Void) {
        guard let value else {
            writeUInt32(0)
            return
        }
        writeUInt32(1)
        body(&self, value)
    }

    public mutating func writeArray<T>(_ values: [T], _ body: (inout XDRWriter, T) -> Void) {
        writeUInt32(UInt32(values.count))
        for value in values { body(&self, value) }
    }

    private mutating func writePadding(for count: Int) {
        let remainder = count % 4
        guard remainder != 0 else { return }
        data.append(Data(repeating: 0, count: 4 - remainder))
    }
}

/// The reading half. Exists because a co-signer must decode a proposed
/// transaction themselves — rendering a payment from the proposer's own
/// description of it would let the proposer describe it as anything.
public struct XDRReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    /// True once every byte has been consumed. Callers that decode a
    /// whole envelope check this: trailing bytes mean the input was not
    /// the thing it claimed to be, and accepting it would let two
    /// implementations disagree about what was signed.
    public var isAtEnd: Bool { offset == data.count }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readUInt32() throws -> UInt32 {
        let bytes = try take(4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    public mutating func readUInt64() throws -> UInt64 {
        let bytes = try take(8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public mutating func readBool() throws -> Bool {
        switch try readInt32() {
        case 0: return false
        case 1: return true
        case let other: throw XDRError.invalidBool(other)
        }
    }

    public mutating func readFixedOpaque(_ count: Int) throws -> Data {
        let bytes = try take(count)
        try skipPadding(for: count)
        return bytes
    }

    /// `maxCount` is not decoration. Every variable-length field in the
    /// Stellar schema is bounded, and the length prefix arrives before
    /// the bytes do — so without a bound, a hostile four-byte prefix
    /// would have us try to allocate 4 GB before discovering the input
    /// was 20 bytes long.
    public mutating func readVariableOpaque(maxCount: Int) throws -> Data {
        let count = Int(try readUInt32())
        guard count <= maxCount else {
            throw XDRError.lengthExceedsBound(count: count, bound: maxCount)
        }
        return try readFixedOpaque(count)
    }

    public mutating func readString(maxCount: Int) throws -> String {
        let bytes = try readVariableOpaque(maxCount: maxCount)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw XDRError.invalidUTF8
        }
        return value
    }

    public mutating func readOptional<T>(_ body: (inout XDRReader) throws -> T) throws -> T? {
        switch try readUInt32() {
        case 0: return nil
        case 1: return try body(&self)
        case let other: throw XDRError.invalidOptionalFlag(other)
        }
    }

    public mutating func readArray<T>(
        maxCount: Int,
        _ body: (inout XDRReader) throws -> T
    ) throws -> [T] {
        let count = Int(try readUInt32())
        guard count <= maxCount else {
            throw XDRError.lengthExceedsBound(count: count, bound: maxCount)
        }
        var values: [T] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try body(&self)) }
        return values
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw XDRError.unexpectedEnd(needed: count, available: data.count - offset)
        }
        let slice = data[data.startIndex + offset ..< data.startIndex + offset + count]
        offset += count
        return Data(slice)
    }

    /// Padding must be zero. A decoder that skipped these bytes without
    /// looking would accept two distinct encodings of the same value,
    /// and a transaction hash is taken over bytes — so "same value,
    /// different bytes" is a different transaction.
    private mutating func skipPadding(for count: Int) throws {
        let remainder = count % 4
        guard remainder != 0 else { return }
        let padding = try take(4 - remainder)
        guard padding.allSatisfy({ $0 == 0 }) else {
            throw XDRError.nonZeroPadding
        }
    }
}

public enum XDRError: Error, Equatable, Sendable {
    case unexpectedEnd(needed: Int, available: Int)
    case nonZeroPadding
    case invalidUTF8
    case invalidBool(Int32)
    case invalidOptionalFlag(UInt32)
    case lengthExceedsBound(count: Int, bound: Int)
    /// A union discriminant this decoder has no arm for. Carries the
    /// type name so the message says which union, not just which number.
    case unknownDiscriminant(type: String, value: Int32)
    /// Trailing bytes after a complete value.
    case trailingBytes(Int)
}
