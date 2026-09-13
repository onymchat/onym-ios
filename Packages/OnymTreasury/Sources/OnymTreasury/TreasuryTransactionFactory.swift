import CryptoKit
import Foundation
import OnymStellar

/// How many signatures a treasury needs, as the group chose them.
public struct TreasuryThresholds: Equatable, Sendable {
    public let low: UInt32
    public let medium: UInt32
    public let high: UInt32

    public init(low: UInt32, medium: UInt32, high: UInt32) {
        self.low = low
        self.medium = medium
        self.high = high
    }

    /// The default offered for a signer set of `count`: a majority to
    /// spend, and the same majority to change who can spend.
    ///
    /// Majority rather than unanimity on purpose. With `high = count`,
    /// a single lost device freezes the signer set permanently — there
    /// would be no way to remove the lost key, because removing it
    /// needs its signature. The creation screen still says plainly what
    /// the chosen numbers cost, because this is a guess about a group
    /// whose circumstances it does not know.
    public static func majority(of count: Int) -> TreasuryThresholds {
        let majority = UInt32(count / 2 + 1)
        return TreasuryThresholds(low: 1, medium: majority, high: majority)
    }
}

/// Builds the transactions a treasury needs. Pure — no I/O, no clock,
/// no randomness beyond the one explicit keypair generator — so every
/// shape it produces is testable against a fixture.
public enum TreasuryTransactionFactory {

    /// Stellar's rule: `(2 + subentries) × baseReserve`. Each signer
    /// beyond the master key is a subentry, and so is each trustline.
    ///
    /// Exposed rather than inlined because the creation screen shows
    /// this arithmetic to the founder. A number a person is asked to
    /// fund should be one they can check.
    public static func minimumBalance(
        signerCount: Int,
        trustlineCount: Int = 0,
        baseReserve: StellarAmount
    ) -> StellarAmount {
        let entries = Int64(2 + signerCount + trustlineCount)
        return StellarAmount(stroops: entries * baseReserve.stroops)
    }

    /// The whole of treasury creation, as one transaction.
    ///
    /// ## Why it must be atomic
    ///
    /// The last operation sets the treasury's master weight to zero. If
    /// setup were spread across transactions, every intermediate state
    /// would be a real one the network could stop at: an account with a
    /// live master key and no co-signers (the founder controls the
    /// money), or thresholds raised before the signers exist (nobody
    /// does, permanently). One envelope has neither — it applies whole
    /// or not at all.
    ///
    /// ## Who signs it
    ///
    /// Two keys. `funder`, because it pays; and the treasury's own
    /// freshly-minted key, because at the moment operations 2..n run
    /// its master weight is still 1 and it is the source of each. That
    /// second key is needed exactly once, for exactly this transaction,
    /// and is worthless afterwards — see `EphemeralTreasuryKey`.
    ///
    /// - Parameter funderSequence: the funder account's *current*
    ///   sequence; the transaction uses the next one.
    public static func creation(
        funder: StellarAccountID,
        funderSequence: Int64,
        treasury: StellarAccountID,
        coSigners: [StellarAccountID],
        thresholds: TreasuryThresholds,
        startingBalance: StellarAmount,
        baseFee: StellarAmount,
        timeBounds: StellarTimeBounds
    ) throws -> StellarTransaction {
        var operations: [StellarOperation] = [
            StellarOperation(body: .createAccount(
                destination: treasury,
                startingBalance: startingBalance
            )),
        ]
        for coSigner in coSigners {
            operations.append(StellarOperation(
                sourceAccount: treasury,
                body: .setOptions(SetOptionsFields(
                    signer: StellarSigner(key: coSigner, weight: 1)
                ))
            ))
        }
        // Last, and only last. Until this applies the treasury's own key
        // still has weight, which is what let the operations above name
        // it as their source.
        operations.append(StellarOperation(
            sourceAccount: treasury,
            body: .setOptions(SetOptionsFields(
                masterWeight: 0,
                lowThreshold: thresholds.low,
                mediumThreshold: thresholds.medium,
                highThreshold: thresholds.high
            ))
        ))
        return try StellarTransaction(
            sourceAccount: funder,
            fee: fee(baseFee: baseFee, operations: operations.count),
            sequenceNumber: funderSequence + 1,
            timeBounds: timeBounds,
            operations: operations
        )
    }

    public static func payment(
        treasury: StellarAccountID,
        treasurySequence: Int64,
        destination: StellarAccountID,
        asset: StellarAsset,
        amount: StellarAmount,
        memo: StellarMemo,
        baseFee: StellarAmount,
        timeBounds: StellarTimeBounds
    ) throws -> StellarTransaction {
        try StellarTransaction(
            sourceAccount: treasury,
            fee: fee(baseFee: baseFee, operations: 1),
            sequenceNumber: treasurySequence + 1,
            timeBounds: timeBounds,
            memo: memo,
            operations: [
                StellarOperation(body: .payment(
                    destination: destination,
                    asset: asset,
                    amount: amount
                )),
            ]
        )
    }

    /// Open a trustline. `limit: .max` means "no ceiling", which is the
    /// ordinary case; a limit of zero would *close* the line, which is
    /// why closing is expressed through this same call rather than a
    /// separate one that could be mistaken for it.
    public static func trustline(
        treasury: StellarAccountID,
        treasurySequence: Int64,
        asset: StellarAsset,
        limit: StellarAmount,
        baseFee: StellarAmount,
        timeBounds: StellarTimeBounds
    ) throws -> StellarTransaction {
        try StellarTransaction(
            sourceAccount: treasury,
            fee: fee(baseFee: baseFee, operations: 1),
            sequenceNumber: treasurySequence + 1,
            timeBounds: timeBounds,
            operations: [
                StellarOperation(body: .changeTrust(asset: asset, limit: limit)),
            ]
        )
    }

    /// Nominate a co-signer, optionally moving the thresholds in the
    /// same breath.
    ///
    /// The pairing is the point. Adding a fifth signer to a treasury
    /// whose medium threshold is 2 quietly makes it *easier* to spend,
    /// because the same two signatures now stand for less of the group.
    /// Letting the threshold move atomically with the signer is what
    /// keeps a nomination from being a dilution nobody voted for.
    public static func addSigner(
        treasury: StellarAccountID,
        treasurySequence: Int64,
        newSigner: StellarAccountID,
        weight: UInt32 = 1,
        newThresholds: TreasuryThresholds?,
        baseFee: StellarAmount,
        timeBounds: StellarTimeBounds
    ) throws -> StellarTransaction {
        var operations = [
            StellarOperation(
                sourceAccount: nil,
                body: .setOptions(SetOptionsFields(
                    signer: StellarSigner(key: newSigner, weight: weight)
                ))
            ),
        ]
        if let newThresholds {
            operations.append(StellarOperation(body: .setOptions(SetOptionsFields(
                lowThreshold: newThresholds.low,
                mediumThreshold: newThresholds.medium,
                highThreshold: newThresholds.high
            ))))
        }
        return try StellarTransaction(
            sourceAccount: treasury,
            fee: fee(baseFee: baseFee, operations: operations.count),
            sequenceNumber: treasurySequence + 1,
            timeBounds: timeBounds,
            operations: operations
        )
    }

    /// Remove a co-signer: the same operation, with weight zero.
    public static func removeSigner(
        treasury: StellarAccountID,
        treasurySequence: Int64,
        signer: StellarAccountID,
        newThresholds: TreasuryThresholds?,
        baseFee: StellarAmount,
        timeBounds: StellarTimeBounds
    ) throws -> StellarTransaction {
        try addSigner(
            treasury: treasury,
            treasurySequence: treasurySequence,
            newSigner: signer,
            weight: 0,
            newThresholds: newThresholds,
            baseFee: baseFee,
            timeBounds: timeBounds
        )
    }

    /// The protocol's fee rule: base fee × operation count, for the
    /// whole transaction.
    private static func fee(baseFee: StellarAmount, operations: Int) -> UInt32 {
        UInt32(clamping: baseFee.stroops * Int64(operations))
    }
}

/// The treasury account's own key, which exists for one transaction and
/// must never outlive it.
///
/// After creation applies, this key has weight zero on the account it
/// belongs to — it can authorise nothing, and there is no operation
/// that would bring it back. Keeping it would therefore add no
/// capability and one liability, so it is generated in memory, used to
/// sign the creation envelope, and zeroed.
///
/// It is deliberately **not** derived from the group secret or any
/// identity. A derived treasury key would be recomputable by whoever
/// holds the input — which for a group secret is every member — and a
/// key several people can reconstruct is not a master key that has been
/// renounced.
public final class EphemeralTreasuryKey {
    private var seed: Data
    public let account: StellarAccountID

    public init() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        self.seed = privateKey.rawRepresentation
        self.account = try StellarAccountID(
            publicKey: Data(privateKey.publicKey.rawRepresentation)
        )
    }

    /// Sign `envelope` in place. The private key is reconstructed for
    /// the call and not handed out — there is no accessor for it, which
    /// is what stops a caller from persisting or logging it.
    public func sign(
        _ envelope: inout TransactionEnvelope,
        network: StellarNetwork
    ) throws {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        try envelope.sign(with: privateKey, network: network)
    }

    deinit {
        seed.resetBytes(in: 0..<seed.count)
    }
}
