import XCTest
@testable import OnymStellar
@testable import OnymTreasury

/// History read as events rather than hashes.
///
/// Each of these builds a real envelope, encodes it the way Horizon
/// returns one, and asks what the screen would say. The point is the
/// decoding: a description assembled from anything this app stored
/// would report what this device believed rather than what the network
/// did, and those differ exactly when it matters.
final class TreasuryHistoryEventTests: XCTestCase {

    private let treasury = TreasuryTestKeys.account(1)
    private let other = TreasuryTestKeys.account(2)

    private func row(
        _ operations: [StellarOperation],
        source: StellarAccountID? = nil,
        successful: Bool = true
    ) throws -> HorizonTransaction {
        let transaction = try StellarTransaction(
            sourceAccount: source ?? treasury,
            fee: 100,
            sequenceNumber: 2,
            timeBounds: nil,
            operations: operations
        )
        return HorizonTransaction(
            hash: "abc",
            ledgerCloseTime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceAccount: source ?? treasury,
            successful: successful,
            feeCharged: StellarAmount(stroops: 100),
            envelopeXDR: TransactionEnvelope(transaction: transaction).base64XDR
        )
    }

    /// The same operation is "someone added" or "we sent", depending on
    /// which side of it the treasury is. A screen that got this
    /// backwards would be worse than the hash it replaced.
    func test_aPayment_readsAsSentOrReceivedDependingOnTheSide() throws {
        let out = try row([StellarOperation(body: .payment(
            destination: other, asset: .native, amount: StellarAmount(stroops: 250_000_000)
        ))])
        guard case .sent(let amount, let asset, let to) =
            TreasuryHistoryEvent(out, treasury: treasury).kind
        else { return XCTFail("expected sent") }
        XCTAssertEqual(amount.decimalString, "25")
        XCTAssertEqual(asset, .native)
        XCTAssertEqual(to, other)

        let incoming = try row(
            [StellarOperation(body: .payment(
                destination: treasury, asset: .native, amount: StellarAmount(stroops: 100)
            ))],
            source: other
        )
        guard case .received(_, _, let from) =
            TreasuryHistoryEvent(incoming, treasury: treasury).kind
        else { return XCTFail("expected received") }
        XCTAssertEqual(from, other)
    }

    /// "The treasury started holding USDC" — the action named by what
    /// it does. The word `trustline` appears nowhere a person acts.
    func test_aTrustline_readsAsStartedOrStoppedHolding() throws {
        let asset = try StellarAsset(code: "USDC", issuer: other)
        let opened = try row([StellarOperation(body: .changeTrust(asset: asset, limit: .max))])
        guard case .startedHolding(let held) =
            TreasuryHistoryEvent(opened, treasury: treasury).kind
        else { return XCTFail("expected startedHolding") }
        XCTAssertEqual(held.code, "USDC")

        let closed = try row([StellarOperation(
            body: .changeTrust(asset: asset, limit: StellarAmount(stroops: 0))
        )])
        guard case .stoppedHolding = TreasuryHistoryEvent(closed, treasury: treasury).kind
        else { return XCTFail("expected stoppedHolding") }
    }

    /// Creation is one transaction: the account, its signers, and the
    /// lockdown. It reads as one event, not as a control change.
    func test_theCreatingTransaction_readsAsCreated() throws {
        let created = try row(
            [
                StellarOperation(body: .createAccount(
                    destination: treasury, startingBalance: StellarAmount(stroops: 20_000_000)
                )),
                StellarOperation(sourceAccount: treasury, body: .setOptions(
                    SetOptionsFields(signer: StellarSigner(key: other, weight: 1))
                )),
                StellarOperation(sourceAccount: treasury, body: .setOptions(
                    SetOptionsFields(masterWeight: 0)
                )),
            ],
            source: other
        )
        guard case .created = TreasuryHistoryEvent(created, treasury: treasury).kind
        else { return XCTFail("expected created") }
    }

    func test_aSignerChange_readsAsChangedControl() throws {
        let changed = try row([StellarOperation(body: .setOptions(
            SetOptionsFields(signer: StellarSigner(key: other, weight: 2))
        ))])
        guard case .changedControl = TreasuryHistoryEvent(changed, treasury: treasury).kind
        else { return XCTFail("expected changedControl") }
    }

    /// An envelope that will not decode still has a true hash and a
    /// true outcome. Inventing a description for it is the one thing
    /// this type must not do.
    func test_anUndecodableEnvelope_saysNothingAboutWhatHappened() {
        let broken = HorizonTransaction(
            hash: "dead",
            ledgerCloseTime: Date(),
            sourceAccount: treasury,
            successful: false,
            feeCharged: StellarAmount(stroops: 100),
            envelopeXDR: "not base64 xdr"
        )
        let event = TreasuryHistoryEvent(broken, treasury: treasury)
        XCTAssertEqual(event.kind, .other)
        XCTAssertEqual(event.hash, "dead")
        XCTAssertFalse(event.successful)
    }
}
