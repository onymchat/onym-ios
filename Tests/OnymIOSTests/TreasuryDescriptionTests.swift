import XCTest
@testable import OnymIOS
import OnymIdentity
import OnymStellar
import OnymTreasury

/// What a co-signer is shown.
///
/// The description is built from the decoded transaction, and these
/// tests hold it to the one rule that matters: it must never present a
/// tidy summary of part of a transaction. A card that explains three
/// operations and silently omits a fourth is how someone signs the one
/// that mattered.
final class TreasuryDescriptionTests: XCTestCase {

    private let treasury = TreasuryTestKeys.account(20)
    private let recipient = TreasuryTestKeys.account(21)
    private let issuer = TreasuryTestKeys.account(22)

    func test_aPayment_namesTheAmountAndRecipientAsPrincipal() throws {
        let description = try describe([
            StellarOperation(body: .payment(
                destination: recipient,
                asset: .native,
                amount: try StellarAmount(decimalString: "25.5")
            )),
        ])
        XCTAssertEqual(description.title, "Pay 25.5 XLM")
        XCTAssertNil(description.caveat)
        // The two things worth checking are flagged for the UI to
        // emphasise, rather than each screen deciding for itself.
        let principal = description.lines.filter(\.isPrincipal).map(\.label)
        XCTAssertEqual(principal, ["Amount", "To"])
        XCTAssertTrue(description.lines.contains {
            $0.value == .account(recipient)
        })
    }

    /// Two issuers can both call their token USDC and only one of them
    /// is the real one, so the issuer is part of what gets shown.
    func test_aCreditPayment_showsTheIssuer() throws {
        let asset = try StellarAsset(code: "USDC", issuer: issuer)
        let description = try describe([
            StellarOperation(body: .payment(
                destination: recipient,
                asset: asset,
                amount: try StellarAmount(decimalString: "1")
            )),
        ])
        XCTAssertEqual(description.title, "Pay 1 USDC")
        XCTAssertTrue(description.lines.contains {
            $0.label == "USDC issued by" && $0.value == .account(issuer)
        })
    }

    func test_aTrustline_saysItCostsAReserve() throws {
        let description = try describe([
            StellarOperation(body: .changeTrust(
                asset: try StellarAsset(code: "USDC", issuer: issuer),
                limit: .max
            )),
        ])
        XCTAssertEqual(description.title, "Hold USDC")
        XCTAssertTrue(description.lines.contains { $0.label == "Reserve" })
        XCTAssertNil(description.caveat)
    }

    func test_aZeroLimitTrustline_readsAsClosing() throws {
        let description = try describe([
            StellarOperation(body: .changeTrust(
                asset: try StellarAsset(code: "USDC", issuer: issuer),
                limit: StellarAmount(stroops: 0)
            )),
        ])
        XCTAssertEqual(description.title, "Stop holding USDC")
    }

    func test_addingASigner_namesTheKey() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(
                signer: StellarSigner(key: recipient, weight: 1)
            ))),
        ])
        XCTAssertEqual(description.title, "Add a co-signer")
        XCTAssertTrue(description.lines.contains {
            $0.label == "Add co-signer" && $0.value == .account(recipient)
        })
    }

    func test_removingASigner_readsAsRemoval() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(
                signer: StellarSigner(key: recipient, weight: 0)
            ))),
        ])
        XCTAssertEqual(description.title, "Remove a co-signer")
        XCTAssertTrue(description.lines.contains { $0.label == "Remove co-signer" })
    }

    /// Re-enabling the treasury's own key would undo the thing that
    /// makes it shared. It is spelled out in capitals rather than
    /// tucked into a threshold row.
    func test_switchingTheMasterKeyBackOn_isCalledOut() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(masterWeight: 1))),
        ])
        let line = try XCTUnwrap(
            description.lines.first { $0.label == "Treasury's own key" }
        )
        XCTAssertTrue(line.isPrincipal)
        guard case .text(let text) = line.value else { return XCTFail("expected text") }
        XCTAssertTrue(text.contains("SWITCHED BACK ON"), text)
    }

    // MARK: - The rule

    /// The test this type exists for. An operation the summary did not
    /// account for produces a caveat telling the reader not to sign —
    /// never a clean description of the rest.
    func test_anUnexplainedExtraOperation_producesARefusalToSummarise() throws {
        let description = try describe([
            StellarOperation(body: .payment(
                destination: recipient,
                asset: .native,
                amount: StellarAmount(stroops: 1)
            )),
            // A second payment the payment branch does not read.
            StellarOperation(body: .payment(
                destination: issuer,
                asset: .native,
                amount: StellarAmount(stroops: 999_999_999)
            )),
        ])
        let caveat = try XCTUnwrap(description.caveat)
        XCTAssertTrue(caveat.contains("Don't sign"), caveat)
    }

    func test_aTransactionThisAppCannotDescribe_saysSo() throws {
        let description = try describe([
            StellarOperation(body: .createAccount(
                destination: recipient,
                startingBalance: StellarAmount(stroops: 1)
            )),
        ])
        let caveat = try XCTUnwrap(description.caveat)
        XCTAssertTrue(caveat.contains("Don't sign"), caveat)
        XCTAssertTrue(description.lines.isEmpty)
    }

    /// A run of setOptions is explained in full, so it must not trip
    /// the extra-operation backstop.
    func test_aRunOfControlChanges_isFullyExplained() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(
                signer: StellarSigner(key: recipient, weight: 1)
            ))),
            StellarOperation(body: .setOptions(SetOptionsFields(
                mediumThreshold: 2,
                highThreshold: 3
            ))),
        ])
        XCTAssertNil(description.caveat)
        XCTAssertTrue(description.lines.contains { $0.label == "Signatures to spend" })
        XCTAssertTrue(description.lines.contains {
            $0.label == "Signatures to change control"
        })
    }

    // MARK: - Helpers

    private func describe(_ operations: [StellarOperation]) throws -> TreasuryProposalDescription {
        let transaction = try StellarTransaction(
            sourceAccount: treasury,
            fee: 100,
            sequenceNumber: 1,
            timeBounds: nil,
            operations: operations
        )
        return TreasuryProposalDescription(TreasuryProposal(
            id: UUID(),
            groupID: String(repeating: "ab", count: 32),
            ownerIdentityID: IdentityID(UUID()),
            proposerBlsPubkeyHex: "aa",
            treasuryAccount: treasury,
            network: .testnet,
            kind: .payment,
            envelope: TransactionEnvelope(transaction: transaction),
            createdAt: Date()
        ))
    }
}
