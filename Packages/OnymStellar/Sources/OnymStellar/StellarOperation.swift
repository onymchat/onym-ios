import Foundation

/// A signer on an account: a key and the weight its signature carries.
///
/// Only the Ed25519 arm is modelled. Stellar also has pre-authorized
/// transaction signers and hash-x signers; both are ways to make an
/// account act without a live key-holder, which is the opposite of what
/// a treasury's co-signers are for. Refusing to decode them means a
/// proposal that would add one is rejected rather than rendered as an
/// ordinary co-signer.
public struct StellarSigner: Equatable, Sendable {
    public let key: StellarAccountID
    public let weight: UInt32

    public init(key: StellarAccountID, weight: UInt32) {
        self.key = key
        self.weight = weight
    }

    func encode(to writer: inout XDRWriter) {
        writer.writeInt32(0) // SIGNER_KEY_TYPE_ED25519
        writer.writeFixedOpaque(key.publicKey)
        writer.writeUInt32(weight)
    }

    static func decode(from reader: inout XDRReader) throws -> StellarSigner {
        let type = try reader.readInt32()
        guard type == 0 else {
            throw XDRError.unknownDiscriminant(type: "SignerKey", value: type)
        }
        let key = try StellarAccountID(publicKey: reader.readFixedOpaque(32))
        return StellarSigner(key: key, weight: try reader.readUInt32())
    }
}

/// The `setOptions` fields this app uses. Every one is optional in the
/// schema and absent means "leave unchanged", which is what makes a
/// single operation able to both add a signer and lower the master
/// weight without disturbing anything else.
///
/// `inflationDest`, `clearFlags`, `setFlags` and `homeDomain` are
/// modelled as *decoded* values even though nothing here constructs
/// them, because a proposal that sets them must be visible to the
/// co-signer reviewing it. A field the decoder silently dropped is a
/// change nobody would see before signing.
public struct SetOptionsFields: Equatable, Sendable {
    public var inflationDestination: StellarAccountID?
    public var clearFlags: UInt32?
    public var setFlags: UInt32?
    public var masterWeight: UInt32?
    public var lowThreshold: UInt32?
    public var mediumThreshold: UInt32?
    public var highThreshold: UInt32?
    public var homeDomain: String?
    public var signer: StellarSigner?

    public init(
        inflationDestination: StellarAccountID? = nil,
        clearFlags: UInt32? = nil,
        setFlags: UInt32? = nil,
        masterWeight: UInt32? = nil,
        lowThreshold: UInt32? = nil,
        mediumThreshold: UInt32? = nil,
        highThreshold: UInt32? = nil,
        homeDomain: String? = nil,
        signer: StellarSigner? = nil
    ) {
        self.inflationDestination = inflationDestination
        self.clearFlags = clearFlags
        self.setFlags = setFlags
        self.masterWeight = masterWeight
        self.lowThreshold = lowThreshold
        self.mediumThreshold = mediumThreshold
        self.highThreshold = highThreshold
        self.homeDomain = homeDomain
        self.signer = signer
    }
}

/// The operations a treasury needs, and deliberately no others.
///
/// The closed set is a security boundary, not a scoping decision. A
/// co-signer reviewing a proposal is shown the decoded operations, so
/// an operation this app cannot decode is one it cannot show — and
/// `mergeAccount` in particular is a single operation that empties a
/// treasury into someone else's account. Anything outside this list
/// fails to decode, and `TreasuryProposalVerifier` refuses the proposal
/// rather than displaying a partial description of it.
public enum StellarOperationBody: Equatable, Sendable {
    case createAccount(destination: StellarAccountID, startingBalance: StellarAmount)
    case payment(destination: StellarAccountID, asset: StellarAsset, amount: StellarAmount)
    case setOptions(SetOptionsFields)
    case changeTrust(asset: StellarAsset, limit: StellarAmount)

    // OperationType discriminants.
    static let typeCreateAccount: Int32 = 0
    static let typePayment: Int32 = 1
    static let typeSetOptions: Int32 = 5
    static let typeChangeTrust: Int32 = 6
}

/// One operation, with the optional per-operation source account that
/// lets a single transaction act on more than one account — which is
/// how treasury creation configures the new account in the same
/// envelope that funds it.
public struct StellarOperation: Equatable, Sendable {
    /// Absent means "the transaction's source account".
    public let sourceAccount: StellarAccountID?
    public let body: StellarOperationBody

    public init(sourceAccount: StellarAccountID? = nil, body: StellarOperationBody) {
        self.sourceAccount = sourceAccount
        self.body = body
    }

    public func encode(to writer: inout XDRWriter) {
        writer.writeOptional(sourceAccount) { $0.writeMuxedAccount($1) }
        switch body {
        case .createAccount(let destination, let startingBalance):
            writer.writeInt32(StellarOperationBody.typeCreateAccount)
            writer.writeAccountID(destination)
            writer.writeInt64(startingBalance.stroops)

        case .payment(let destination, let asset, let amount):
            writer.writeInt32(StellarOperationBody.typePayment)
            writer.writeMuxedAccount(destination)
            asset.encode(to: &writer)
            writer.writeInt64(amount.stroops)

        case .setOptions(let fields):
            writer.writeInt32(StellarOperationBody.typeSetOptions)
            writer.writeOptional(fields.inflationDestination) { $0.writeAccountID($1) }
            writer.writeOptional(fields.clearFlags) { $0.writeUInt32($1) }
            writer.writeOptional(fields.setFlags) { $0.writeUInt32($1) }
            writer.writeOptional(fields.masterWeight) { $0.writeUInt32($1) }
            writer.writeOptional(fields.lowThreshold) { $0.writeUInt32($1) }
            writer.writeOptional(fields.mediumThreshold) { $0.writeUInt32($1) }
            writer.writeOptional(fields.highThreshold) { $0.writeUInt32($1) }
            writer.writeOptional(fields.homeDomain) { $0.writeString($1) }
            writer.writeOptional(fields.signer) { $1.encode(to: &$0) }

        case .changeTrust(let asset, let limit):
            writer.writeInt32(StellarOperationBody.typeChangeTrust)
            asset.encode(to: &writer)
            writer.writeInt64(limit.stroops)
        }
    }

    public static func decode(from reader: inout XDRReader) throws -> StellarOperation {
        let source = try reader.readOptional { try $0.readMuxedAccount() }
        let type = try reader.readInt32()
        switch type {
        case StellarOperationBody.typeCreateAccount:
            let destination = try reader.readAccountID()
            let balance = StellarAmount(stroops: try reader.readInt64())
            return StellarOperation(
                sourceAccount: source,
                body: .createAccount(destination: destination, startingBalance: balance)
            )

        case StellarOperationBody.typePayment:
            let destination = try reader.readMuxedAccount()
            let asset = try StellarAsset.decode(from: &reader)
            let amount = StellarAmount(stroops: try reader.readInt64())
            return StellarOperation(
                sourceAccount: source,
                body: .payment(destination: destination, asset: asset, amount: amount)
            )

        case StellarOperationBody.typeSetOptions:
            var fields = SetOptionsFields()
            fields.inflationDestination = try reader.readOptional { try $0.readAccountID() }
            fields.clearFlags = try reader.readOptional { try $0.readUInt32() }
            fields.setFlags = try reader.readOptional { try $0.readUInt32() }
            fields.masterWeight = try reader.readOptional { try $0.readUInt32() }
            fields.lowThreshold = try reader.readOptional { try $0.readUInt32() }
            fields.mediumThreshold = try reader.readOptional { try $0.readUInt32() }
            fields.highThreshold = try reader.readOptional { try $0.readUInt32() }
            // string32 — the schema's bound, enforced so a hostile
            // length prefix can't drive an allocation.
            fields.homeDomain = try reader.readOptional { try $0.readString(maxCount: 32) }
            fields.signer = try reader.readOptional { try StellarSigner.decode(from: &$0) }
            return StellarOperation(sourceAccount: source, body: .setOptions(fields))

        case StellarOperationBody.typeChangeTrust:
            let asset = try StellarAsset.decode(from: &reader)
            let limit = StellarAmount(stroops: try reader.readInt64())
            return StellarOperation(
                sourceAccount: source,
                body: .changeTrust(asset: asset, limit: limit)
            )

        default:
            throw XDRError.unknownDiscriminant(type: "Operation", value: type)
        }
    }
}
