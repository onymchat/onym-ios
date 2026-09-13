import CryptoKit
import XCTest
@testable import OnymIOS
import OnymStellar
import OnymTreasury

/// The creation transaction, the reserve arithmetic, and the check that
/// stops a group being anchored to an account somebody still controls.
final class TreasuryCreationTests: XCTestCase {

    private let funder = TreasuryTestKeys.account(40)
    private let treasury = TreasuryTestKeys.account(41)
    private let coSignerA = TreasuryTestKeys.account(42)
    private let coSignerB = TreasuryTestKeys.account(43)
    private let baseFee = StellarAmount(stroops: 100)
    private let baseReserve = StellarAmount(stroops: 5_000_000)

    // MARK: - The creation envelope

    /// The shape the whole design depends on: fund, install every
    /// co-signer, then switch the account's own key off — in one
    /// transaction, with the lockdown last.
    func test_creation_isOneEnvelopeEndingInTheLockdown() throws {
        let transaction = try makeCreation(coSigners: [coSignerA, coSignerB])

        XCTAssertEqual(transaction.sourceAccount, funder)
        XCTAssertEqual(transaction.operations.count, 4)

        guard case .createAccount(let destination, _) = transaction.operations[0].body else {
            return XCTFail("first operation must fund the account")
        }
        XCTAssertEqual(destination, treasury)
        // The funding operation runs as the funder, not the treasury.
        XCTAssertNil(transaction.operations[0].sourceAccount)

        // Every configuration operation acts on the treasury, which is
        // only possible because its master key still has weight at that
        // point in the transaction.
        for operation in transaction.operations.dropFirst() {
            XCTAssertEqual(operation.sourceAccount, treasury)
        }

        let signerKeys = transaction.operations.dropFirst().compactMap { operation -> StellarAccountID? in
            guard case .setOptions(let fields) = operation.body else { return nil }
            return fields.signer?.key
        }
        XCTAssertEqual(signerKeys, [coSignerA, coSignerB])

        guard case .setOptions(let last) = transaction.operations.last?.body else {
            return XCTFail("last operation must be the lockdown")
        }
        XCTAssertEqual(last.masterWeight, 0)
        XCTAssertEqual(last.mediumThreshold, 2)
        XCTAssertEqual(last.highThreshold, 2)
        XCTAssertNil(last.signer, "the lockdown must not also add a signer")
    }

    /// The window itself, not the bounds this test handed in. A
    /// creation envelope is signed and submitted in one sitting, and a
    /// stale one should lapse rather than linger as a transaction that
    /// can still spend the founder's funds.
    ///
    /// The floor is the half that was missing. At ten minutes the
    /// external path was a race against a person reading four
    /// operations in another app, and a wallet that finds `maxTime`
    /// passed is entitled to refuse — quietly, in the ones that do.
    /// Half an hour is the least that leaves room for a handoff; the
    /// ceiling keeps it a sitting rather than a standing offer.
    func test_theCreationWindow_leavesRoomForAHandoffAndStillLapses() {
        XCTAssertGreaterThanOrEqual(TreasuryCreationInteractor.creationWindow, 1800)
        XCTAssertLessThanOrEqual(TreasuryCreationInteractor.creationWindow, 3600)
        // And far shorter than a proposal's, which people sign across
        // time zones.
        XCTAssertLessThan(
            TreasuryCreationInteractor.creationWindow,
            TreasuryProposalInteractor.proposalWindow
        )
    }

    func test_creation_carriesATimeBoundSoAnUnsentOneLapses() throws {
        let transaction = try makeCreation(coSigners: [coSignerA])
        XCTAssertNotNil(transaction.timeBounds)
        XCTAssertGreaterThan(transaction.timeBounds?.maxTime ?? 0, 0)
    }

    func test_fee_isBaseFeeTimesOperationCount() throws {
        let one = try makeCreation(coSigners: [coSignerA])
        let two = try makeCreation(coSigners: [coSignerA, coSignerB])
        XCTAssertEqual(one.fee, 300)  // create + 1 signer + lockdown
        XCTAssertEqual(two.fee, 400)
    }

    // MARK: - Reserve arithmetic

    /// The number the founder is shown and asked to check.
    func test_minimumBalance_isTwoPlusSubentriesTimesTheBaseReserve() {
        XCTAssertEqual(
            TreasuryTransactionFactory.minimumBalance(
                signerCount: 0,
                baseReserve: baseReserve
            ).decimalString,
            "1"  // 2 × 0.5
        )
        XCTAssertEqual(
            TreasuryTransactionFactory.minimumBalance(
                signerCount: 3,
                baseReserve: baseReserve
            ).decimalString,
            "2.5"  // (2 + 3) × 0.5
        )
        // A planned trustline is a subentry too.
        XCTAssertEqual(
            TreasuryTransactionFactory.minimumBalance(
                signerCount: 3,
                trustlineCount: 1,
                baseReserve: baseReserve
            ).decimalString,
            "3"
        )
    }

    // MARK: - Thresholds

    /// Majority rather than unanimity: with `high = count`, one lost
    /// device freezes the signer set permanently, because removing a
    /// key needs that key's signature.
    func test_defaultThresholds_areAMajorityNotUnanimity() {
        XCTAssertEqual(TreasuryThresholds.majority(of: 2).medium, 2)
        XCTAssertEqual(TreasuryThresholds.majority(of: 3).medium, 2)
        XCTAssertEqual(TreasuryThresholds.majority(of: 3).high, 2)
        XCTAssertEqual(TreasuryThresholds.majority(of: 5).medium, 3)
        XCTAssertLessThan(TreasuryThresholds.majority(of: 5).high, 5)
        // Low stays at one: a minor change should not need a quorum.
        XCTAssertEqual(TreasuryThresholds.majority(of: 5).low, 1)
    }

    // MARK: - The ephemeral key

    /// The treasury's own key exists for one transaction. It is
    /// generated in memory, signs, and is never exposed — there is no
    /// accessor for it, which is what stops a caller persisting it.
    func test_theEphemeralKey_signsItsOwnCreationEnvelope() throws {
        let key = try EphemeralTreasuryKey()
        var envelope = TransactionEnvelope(transaction: try makeCreation(
            coSigners: [coSignerA],
            treasury: key.account
        ))
        try key.sign(&envelope, network: .testnet)

        XCTAssertEqual(envelope.signatures.count, 1)
        XCTAssertTrue(envelope.hasSignature(from: key.account, network: .testnet))
    }

    func test_twoEphemeralKeys_areDifferentAccounts() throws {
        // Not derived from the group secret or an identity: a key that
        // several people can recompute is not a renounced master key.
        let a = try EphemeralTreasuryKey()
        let b = try EphemeralTreasuryKey()
        XCTAssertNotEqual(a.account, b.account)
    }

    // MARK: - Other proposal shapes

    func test_addSigner_canMoveTheThresholdAtomically() throws {
        let transaction = try TreasuryTransactionFactory.addSigner(
            treasury: treasury,
            treasurySequence: 4,
            newSigner: coSignerB,
            newThresholds: TreasuryThresholds(low: 1, medium: 3, high: 3),
            baseFee: baseFee,
            timeBounds: bounds
        )
        // Pairing them is the point: adding a fifth signer without
        // moving the threshold quietly makes spending easier. Asserting
        // only the count would pass if the thresholds were dropped.
        XCTAssertEqual(transaction.operations.count, 2)
        XCTAssertEqual(transaction.sequenceNumber, 5)

        guard case .setOptions(let first) = transaction.operations[0].body else {
            return XCTFail("the first operation should add the signer")
        }
        XCTAssertEqual(first.signer?.key, coSignerB)
        XCTAssertEqual(first.signer?.weight, 1)
        XCTAssertNil(first.mediumThreshold, "the signer op must not also move thresholds")

        guard case .setOptions(let second) = transaction.operations[1].body else {
            return XCTFail("the second operation should move the thresholds")
        }
        XCTAssertEqual(second.mediumThreshold, 3)
        XCTAssertEqual(second.highThreshold, 3)
        XCTAssertNil(second.signer)
    }

    func test_removeSigner_isTheSameOperationWithZeroWeight() throws {
        let transaction = try TreasuryTransactionFactory.removeSigner(
            treasury: treasury,
            treasurySequence: 4,
            signer: coSignerB,
            newThresholds: nil,
            baseFee: baseFee,
            timeBounds: bounds
        )
        guard case .setOptions(let fields) = transaction.operations[0].body else {
            return XCTFail("expected setOptions")
        }
        XCTAssertEqual(fields.signer?.weight, 0)
        XCTAssertEqual(fields.signer?.key, coSignerB)
    }

    func test_everyProposalTakesTheNextSequenceNumber() throws {
        let payment = try TreasuryTransactionFactory.payment(
            treasury: treasury,
            treasurySequence: 41,
            destination: coSignerA,
            asset: .native,
            amount: StellarAmount(stroops: 1),
            memo: .none,
            baseFee: baseFee,
            timeBounds: bounds
        )
        XCTAssertEqual(payment.sequenceNumber, 42)
    }

    // MARK: - Helpers

    private var bounds: StellarTimeBounds {
        StellarTimeBounds(minTime: 0, maxTime: 4_000_000_000)
    }

    private func makeCreation(
        coSigners: [StellarAccountID],
        treasury override: StellarAccountID? = nil
    ) throws -> StellarTransaction {
        try TreasuryTransactionFactory.creation(
            funder: funder,
            funderSequence: 10,
            treasury: override ?? treasury,
            coSigners: coSigners,
            thresholds: TreasuryThresholds.majority(of: coSigners.count),
            startingBalance: StellarAmount(stroops: 20_000_000),
            baseFee: baseFee,
            timeBounds: bounds
        )
    }
}
