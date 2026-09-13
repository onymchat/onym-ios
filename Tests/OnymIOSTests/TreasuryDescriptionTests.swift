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
        XCTAssertEqual(String(localized: description.title), "Pay 25.5 XLM")
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
        XCTAssertEqual(String(localized: description.title), "Pay 1 USDC")
        // The key is the format string now; the asset code is an
        // argument. Checked through the rendered label so the
        // assertion says what a reader sees.
        XCTAssertTrue(description.lines.contains {
            String(localized: $0.label) == "USDC issued by"
                && $0.value == .account(issuer)
        })
    }

    func test_aTrustline_saysItCostsAReserve() throws {
        let description = try describe([
            StellarOperation(body: .changeTrust(
                asset: try StellarAsset(code: "USDC", issuer: issuer),
                limit: .max
            )),
        ])
        XCTAssertEqual(String(localized: description.title), "Hold USDC")
        XCTAssertTrue(description.lines.contains { $0.label.key == "Reserve" })
        XCTAssertNil(description.caveat)
    }

    func test_aZeroLimitTrustline_readsAsClosing() throws {
        let description = try describe([
            StellarOperation(body: .changeTrust(
                asset: try StellarAsset(code: "USDC", issuer: issuer),
                limit: StellarAmount(stroops: 0)
            )),
        ])
        XCTAssertEqual(String(localized: description.title), "Stop holding USDC")
    }

    func test_addingASigner_namesTheKey() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(
                signer: StellarSigner(key: recipient, weight: 1)
            ))),
        ])
        XCTAssertEqual(description.title, "Add a co-signer")
        XCTAssertTrue(description.lines.contains {
            $0.label.key == "Add co-signer" && $0.value == .account(recipient)
        })
    }

    func test_removingASigner_readsAsRemoval() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(
                signer: StellarSigner(key: recipient, weight: 0)
            ))),
        ])
        XCTAssertEqual(description.title, "Remove a co-signer")
        XCTAssertTrue(description.lines.contains { $0.label.key == "Remove co-signer" })
    }

    /// Re-enabling the treasury's own key would undo the thing that
    /// makes it shared. It is spelled out in capitals rather than
    /// tucked into a threshold row.
    func test_switchingTheMasterKeyBackOn_isCalledOut() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(masterWeight: 1))),
        ])
        let line = try XCTUnwrap(
            description.lines.first { $0.label.key == "Treasury's own key" }
        )
        XCTAssertTrue(line.isPrincipal)
        // `.copy`, not `.text`: this line is a sentence this app wrote,
        // and the two cases exist to keep that apart from a stranger's
        // bytes.
        guard case .copy(let resource) = line.value else { return XCTFail("expected copy") }
        let text = String(localized: resource)
        XCTAssertTrue(text.contains("SWITCHED BACK ON"), text)
    }

    /// The memo, which had no coverage at all — the whole `switch`
    /// could have been deleted with nothing failing, on the field the
    /// source itself calls out as the one that decides which customer
    /// an exchange credits.
    func test_aTextMemo_isShownAsPrincipal() throws {
        let description = try describe(
            [payment()],
            memo: .text("order-4417")
        )
        let line = try XCTUnwrap(description.lines.first { $0.label.key == "Memo" })
        XCTAssertEqual(line.value, .text("order-4417"))
        XCTAssertTrue(line.isPrincipal, "a memo routes money and must stand out")
    }

    func test_anIdMemo_isShown() throws {
        let description = try describe([payment()], memo: .id(902_144))
        let line = try XCTUnwrap(description.lines.first { $0.label.key == "Memo (id)" })
        XCTAssertEqual(line.value, .text("902144"))
    }

    func test_aHashMemo_isShown() throws {
        let description = try describe(
            [payment()],
            memo: .hash(Data(repeating: 0xAB, count: 32))
        )
        let line = try XCTUnwrap(description.lines.first { $0.label.key == "Memo (hash)" })
        XCTAssertEqual(line.value, .text(String(repeating: "ab", count: 32)))
    }

    func test_noMemo_addsNoLine() throws {
        let description = try describe([payment()])
        XCTAssertFalse(description.lines.contains { $0.label.key.hasPrefix("Memo") })
    }

    /// The fields `StellarOperation` decodes so a co-signer can see
    /// them. A one-op `setOptions{setFlags:}` is *accepted* by the
    /// verifier, and used to render with an empty details box and no
    /// caveat — a tidy summary of a control change it did not describe.
    func test_accountFlags_areNamedRatherThanOmitted() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(setFlags: 0x4))),
        ])
        let line = try XCTUnwrap(
            description.lines.first { $0.label.key == "Turns on account flags" }
        )
        // `.copy`, because the line is a flag word *and* a sentence
        // about it — "AUTH_IMMUTABLE cannot be undone" is this app
        // talking, not bytes off the wire, and only the `.copy` half
        // can be translated.
        guard case .copy(let resource) = line.value else { return XCTFail("expected copy") }
        let text = String(localized: resource)
        XCTAssertTrue(text.contains("AUTH_IMMUTABLE"), text)
        XCTAssertTrue(text.contains("cannot be undone"), text)
        XCTAssertTrue(line.isPrincipal)
    }

    /// The other two of the four, which the first version of this file
    /// left unpinned — and they are the same shape as the bug it was
    /// written to catch. A one-op `setOptions{inflationDestination:}`
    /// verifies as a control change, so it renders under the title
    /// "Change how many signatures are needed" and counts as explained,
    /// meaning no caveat fires either.
    func test_clearedFlags_areNamedRatherThanOmitted() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(clearFlags: 0x2))),
        ])
        let line = try XCTUnwrap(
            description.lines.first { $0.label.key == "Turns off account flags" }
        )
        // `.text` here and `.copy` above, deliberately: a flag word
        // with nothing to say about it is data, and `AUTH_REVOCABLE`
        // carries no warning the way `AUTH_IMMUTABLE` does.
        guard case .text(let text) = line.value else { return XCTFail("expected text") }
        XCTAssertTrue(text.contains("AUTH_REVOCABLE"), text)
        XCTAssertTrue(line.isPrincipal)
    }

    func test_anInflationDestination_isShown() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(
                SetOptionsFields(inflationDestination: recipient)
            )),
        ])
        let line = try XCTUnwrap(
            description.lines.first { $0.label.key == "Inflation destination" }
        )
        XCTAssertEqual(line.value, .account(recipient))
        XCTAssertTrue(line.isPrincipal)
        XCTAssertNil(description.caveat)
    }

    func test_aHomeDomainChange_isShown() throws {
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(homeDomain: "example.com"))),
        ])
        XCTAssertTrue(description.lines.contains {
            $0.label.key == "Home domain" && $0.value == .text("example.com")
        })
    }

    /// Two co-signers, two addresses. `Line.id` was the label, and
    /// `describeControl` labels every added account identically, so
    /// `ForEach` collapsed them into one row — with the whole
    /// `setOptions` run counted as explained, so no caveat fired.
    func test_twoAddedCoSigners_renderAsTwoDistinctLines() throws {
        let first = TreasuryTestKeys.account(24)
        let second = TreasuryTestKeys.account(25)
        let description = try describe([
            StellarOperation(body: .setOptions(SetOptionsFields(
                signer: StellarSigner(key: first, weight: 1)
            ))),
            StellarOperation(body: .setOptions(SetOptionsFields(
                signer: StellarSigner(key: second, weight: 1)
            ))),
        ])
        let added = description.lines.filter { $0.label.key == "Add co-signer" }
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(Set(added.map(\.id)).count, 2, "both rows must survive ForEach")
        XCTAssertTrue(added.contains { $0.value == .account(first) })
        XCTAssertTrue(added.contains { $0.value == .account(second) })
    }

    /// And identity is derived, so an identically-derived description
    /// stays equal — otherwise every snapshot re-identifies every line
    /// and tears down the address the card asks people to check.
    func test_twoIdenticalDescriptions_areEqual() throws {
        let operations = [payment()]
        XCTAssertEqual(try describe(operations), try describe(operations))
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
        let caveat = String(localized: try XCTUnwrap(description.caveat))
        XCTAssertTrue(caveat.contains("Don't sign"), caveat)
    }

    func test_aTransactionThisAppCannotDescribe_saysSo() throws {
        let description = try describe([
            StellarOperation(body: .createAccount(
                destination: recipient,
                startingBalance: StellarAmount(stroops: 1)
            )),
        ])
        let caveat = String(localized: try XCTUnwrap(description.caveat))
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
        XCTAssertTrue(description.lines.contains { $0.label.key == "Signatures to spend" })
        XCTAssertTrue(description.lines.contains {
            $0.label.key == "Signatures to change control"
        })
    }

    // MARK: - Helpers

    private func payment() -> StellarOperation {
        StellarOperation(body: .payment(
            destination: recipient,
            asset: .native,
            amount: StellarAmount(stroops: 1)
        ))
    }

    private func describe(
        _ operations: [StellarOperation],
        memo: StellarMemo = .none
    ) throws -> TreasuryProposalDescription {
        let transaction = try StellarTransaction(
            sourceAccount: treasury,
            fee: 100,
            sequenceNumber: 1,
            timeBounds: nil,
            memo: memo,
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
