import CryptoKit
import Foundation

/// A transaction memo. Modelled in full because a co-signer must see
/// one: exchanges and custodians route deposits by memo, and a payment
/// whose memo was dropped in display but present in the signed bytes is
/// a payment that credits the wrong customer.
public enum StellarMemo: Equatable, Sendable {
    case none
    /// Up to 28 **bytes** of UTF-8, not 28 characters.
    case text(String)
    case id(UInt64)
    case hash(Data)
    case returnHash(Data)

    func encode(to writer: inout XDRWriter) {
        switch self {
        case .none:
            writer.writeInt32(0)
        case .text(let value):
            writer.writeInt32(1)
            // `string<28>` is a byte bound, and it is checked on the way
            // out as well as in. Encoding an over-long memo produces an
            // envelope the network refuses *after* the group has signed
            // it — the signatures are over bytes, so there is no fixing
            // it afterwards.
            precondition(
                Data(value.utf8).count <= 28,
                "memo text exceeds the protocol's 28 bytes"
            )
            writer.writeString(value)
        case .id(let value):
            writer.writeInt32(2)
            writer.writeUInt64(value)
        case .hash(let value):
            writer.writeInt32(3)
            writer.writeFixedOpaque(value)
        case .returnHash(let value):
            writer.writeInt32(4)
            writer.writeFixedOpaque(value)
        }
    }

    static func decode(from reader: inout XDRReader) throws -> StellarMemo {
        let type = try reader.readInt32()
        switch type {
        case 0: return .none
        case 1: return .text(try reader.readString(maxCount: 28))
        case 2: return .id(try reader.readUInt64())
        case 3: return .hash(try reader.readFixedOpaque(32))
        case 4: return .returnHash(try reader.readFixedOpaque(32))
        default: throw XDRError.unknownDiscriminant(type: "Memo", value: type)
        }
    }
}

/// Unix seconds bounding when a transaction may be applied. `maxTime`
/// is what stops an unsubmitted proposal from being resurrected years
/// later once everyone has forgotten it, so treasury proposals always
/// set one.
public struct StellarTimeBounds: Equatable, Sendable {
    public let minTime: UInt64
    public let maxTime: UInt64

    public init(minTime: UInt64, maxTime: UInt64) {
        self.minTime = minTime
        self.maxTime = maxTime
    }
}

/// A Stellar transaction, in the V1 (`ENVELOPE_TYPE_TX`) shape.
///
/// Preconditions are modelled as `PRECOND_NONE` / `PRECOND_TIME` only.
/// `PRECOND_V2` carries extra signers and ledger-bound conditions that
/// change who can satisfy a transaction; refusing to decode it keeps a
/// proposal whose conditions this app cannot show from being shown as
/// though it had none.
public struct StellarTransaction: Equatable, Sendable {
    /// Maximum operations per transaction in the protocol.
    public static let maxOperations = 100

    public let sourceAccount: StellarAccountID
    /// Total fee in stroops, which the protocol defines as
    /// `baseFee × operationCount` — the whole transaction's fee, not
    /// the per-operation rate.
    public let fee: UInt32
    /// Must be exactly one more than the source account's current
    /// sequence at apply time. This is what makes two proposals built
    /// against the same account state mutually exclusive.
    public let sequenceNumber: Int64
    public let timeBounds: StellarTimeBounds?
    public let memo: StellarMemo
    public let operations: [StellarOperation]

    public init(
        sourceAccount: StellarAccountID,
        fee: UInt32,
        sequenceNumber: Int64,
        timeBounds: StellarTimeBounds?,
        memo: StellarMemo = .none,
        operations: [StellarOperation]
    ) throws {
        guard (1...Self.maxOperations).contains(operations.count) else {
            throw StellarError.tooManyOperations(operations.count)
        }
        self.sourceAccount = sourceAccount
        self.fee = fee
        self.sequenceNumber = sequenceNumber
        self.timeBounds = timeBounds
        self.memo = memo
        self.operations = operations
    }

    public func encode(to writer: inout XDRWriter) {
        writer.writeMuxedAccount(sourceAccount)
        writer.writeUInt32(fee)
        writer.writeInt64(sequenceNumber)
        if let timeBounds {
            writer.writeInt32(1) // PRECOND_TIME
            writer.writeUInt64(timeBounds.minTime)
            writer.writeUInt64(timeBounds.maxTime)
        } else {
            writer.writeInt32(0) // PRECOND_NONE
        }
        memo.encode(to: &writer)
        writer.writeArray(operations) { $1.encode(to: &$0) }
        writer.writeInt32(0) // ext: void
    }

    public static func decode(from reader: inout XDRReader) throws -> StellarTransaction {
        let source = try reader.readMuxedAccount()
        let fee = try reader.readUInt32()
        let sequence = try reader.readInt64()
        let precondition = try reader.readInt32()
        var bounds: StellarTimeBounds?
        switch precondition {
        case 0: // PRECOND_NONE
            bounds = nil
        case 1: // PRECOND_TIME
            bounds = StellarTimeBounds(
                minTime: try reader.readUInt64(),
                maxTime: try reader.readUInt64()
            )
        default: // includes PRECOND_V2
            throw XDRError.unknownDiscriminant(type: "Preconditions", value: precondition)
        }
        let memo = try StellarMemo.decode(from: &reader)
        let operations = try reader.readArray(maxCount: maxOperations) {
            try StellarOperation.decode(from: &$0)
        }
        let ext = try reader.readInt32()
        guard ext == 0 else {
            throw XDRError.unknownDiscriminant(type: "Transaction.ext", value: ext)
        }
        return try StellarTransaction(
            sourceAccount: source,
            fee: fee,
            sequenceNumber: sequence,
            timeBounds: bounds,
            memo: memo,
            operations: operations
        )
    }

    /// The 32 bytes every signer signs.
    ///
    ///     SHA256( networkId ‖ int32(ENVELOPE_TYPE_TX) ‖ XDR(Transaction) )
    ///
    /// The network id is inside the hash, which is why a signature
    /// collected on testnet cannot be replayed against the public
    /// network — the same transaction has a different hash on each.
    public func hash(network: StellarNetwork) -> Data {
        var writer = XDRWriter()
        writer.writeFixedOpaque(network.id)
        writer.writeInt32(EnvelopeType.transaction)
        encode(to: &writer)
        return Data(SHA256.hash(data: writer.data))
    }
}

enum EnvelopeType {
    static let transaction: Int32 = 2
}
