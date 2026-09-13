import Foundation

/// What an account looks like from Horizon, reduced to what a treasury
/// screen needs.
public struct HorizonAccount: Equatable, Sendable {
    public let accountID: StellarAccountID
    /// Current sequence. A transaction must use this **plus one**.
    public let sequenceNumber: Int64
    public let balances: [HorizonBalance]
    public let signers: [StellarSigner]
    public let thresholds: HorizonThresholds

    public init(
        accountID: StellarAccountID,
        sequenceNumber: Int64,
        balances: [HorizonBalance],
        signers: [StellarSigner],
        thresholds: HorizonThresholds
    ) {
        self.accountID = accountID
        self.sequenceNumber = sequenceNumber
        self.balances = balances
        self.signers = signers
        self.thresholds = thresholds
    }

    /// Weight available from `candidates` — what a proposal has to reach
    /// to be submittable. Derived from the account's **live** signer
    /// list rather than from anything stored locally, because the signer
    /// set is exactly what a `setOptions` proposal changes.
    public func weight(of candidates: [StellarAccountID]) -> UInt32 {
        signers
            .filter { signer in candidates.contains(signer.key) }
            .reduce(UInt32(0)) { $0 + $1.weight }
    }
}

public struct HorizonBalance: Equatable, Sendable {
    public let asset: StellarAsset
    public let balance: StellarAmount
    /// Nil for the native balance, which has no ceiling.
    public let limit: StellarAmount?

    public init(asset: StellarAsset, balance: StellarAmount, limit: StellarAmount?) {
        self.asset = asset
        self.balance = balance
        self.limit = limit
    }
}

public struct HorizonThresholds: Equatable, Sendable {
    public let low: UInt32
    public let medium: UInt32
    public let high: UInt32

    public init(low: UInt32, medium: UInt32, high: UInt32) {
        self.low = low
        self.medium = medium
        self.high = high
    }
}

/// One applied transaction against the treasury, for the history list.
public struct HorizonTransaction: Equatable, Sendable {
    public let hash: String
    public let ledgerCloseTime: Date
    public let sourceAccount: StellarAccountID
    public let successful: Bool
    public let feeCharged: StellarAmount
    /// The envelope as Horizon returned it, so the history row can be
    /// decoded and rendered with the same code that renders a proposal
    /// — rather than a second, drifting description of the same
    /// operations.
    public let envelopeXDR: String

    public init(
        hash: String,
        ledgerCloseTime: Date,
        sourceAccount: StellarAccountID,
        successful: Bool,
        feeCharged: StellarAmount,
        envelopeXDR: String
    ) {
        self.hash = hash
        self.ledgerCloseTime = ledgerCloseTime
        self.sourceAccount = sourceAccount
        self.successful = successful
        self.feeCharged = feeCharged
        self.envelopeXDR = envelopeXDR
    }
}

/// Network seam for the classic-Stellar leg.
///
/// A protocol because the traffic is expected to move: today a
/// `URLSessionHorizonClient` talks to Horizon straight from the device,
/// which means the device's address reaches a third party and the app's
/// "all chain traffic goes through the relayer" posture does not yet
/// hold for treasuries. Routing it behind the relayer later is a
/// different conformer, not a change to any caller.
public protocol HorizonClient: Sendable {
    func account(_ id: StellarAccountID) async throws -> HorizonAccount
    /// Applied transactions for `id`, newest first.
    func transactions(for id: StellarAccountID, limit: Int) async throws -> [HorizonTransaction]
    /// Submit a signed envelope. Returns the applied transaction's hash.
    func submit(_ envelope: TransactionEnvelope) async throws -> String
    /// Current base reserve and base fee, which decide the minimum
    /// balance a new treasury needs. Read rather than hardcoded: both
    /// are protocol parameters and have been changed by validator vote
    /// before.
    func networkParameters() async throws -> HorizonNetworkParameters
}

public struct HorizonNetworkParameters: Equatable, Sendable {
    public let baseFee: StellarAmount
    public let baseReserve: StellarAmount

    public init(baseFee: StellarAmount, baseReserve: StellarAmount) {
        self.baseFee = baseFee
        self.baseReserve = baseReserve
    }
}

public enum HorizonError: Error, Equatable, Sendable {
    case invalidResponse(statusCode: Int, body: String)
    case decodeFailure(String)
    case accountNotFound(String)
    /// Horizon rejected the submission. `resultCodes` carries the
    /// protocol's own reason strings (`tx_bad_seq`, `op_underfunded`,
    /// …) because they are the only description precise enough to tell
    /// a superseded proposal apart from an underfunded one.
    case submissionFailed(resultCodes: [String], body: String)
}
