import XCTest
@testable import OnymStellar

/// The test that makes a hand-written XDR codec trustworthy.
///
/// Every case in `Fixtures/fixtures.json` was produced by an
/// independent implementation (`stellar-sdk` 15.0.0 for Python, via
/// `scripts/generate-stellar-fixtures.py`). Three things are checked
/// against each one:
///
///  1. **Decode → encode is byte-identical.** Proves the reader and the
///     writer agree with a third party about the same bytes, not merely
///     with each other — which a round-trip of our own output would not.
///  2. **The transaction hash matches.** This is the value signatures
///     are made over, so a codec that encoded a field in the wrong
///     place but round-tripped cleanly would still produce signatures
///     the network rejects. The hash is the check that catches it.
///  3. **Building from scratch reproduces the fixture** for the shapes
///     this app constructs, which covers the writer on the path that
///     actually moves money.
final class StellarXDRFixtureTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixtures: Decodable {
        struct Case: Decodable {
            let xdr: String
            let hash: String
            let passphrase: String
        }
        struct Meta: Decodable {
            let accounts: [String: String]
            let secrets: [String: String]
        }
        let meta: Meta
        let cases: [String: Case]
    }

    private lazy var fixtures: Fixtures = {
        guard let url = Bundle.module.url(
            forResource: "fixtures",
            withExtension: "json",
            subdirectory: "Fixtures"
        ), let data = try? Data(contentsOf: url) else {
            fatalError("fixtures.json missing from the test bundle")
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixtures.self, from: data)
    }()

    private func account(_ name: String) throws -> StellarAccountID {
        try StellarAccountID(accountID: XCTUnwrap(fixtures.meta.accounts[name]))
    }

    // MARK: - 1 + 2: every fixture round-trips and hashes correctly

    func test_everyFixture_reencodesToTheSameBytesAndHash() throws {
        XCTAssertFalse(fixtures.cases.isEmpty)
        for (name, fixture) in fixtures.cases {
            let envelope = try TransactionEnvelope(base64XDR: fixture.xdr)

            XCTAssertEqual(
                envelope.base64XDR,
                fixture.xdr,
                "\(name): re-encoded bytes differ from the reference envelope"
            )

            let network = try XCTUnwrap(
                StellarNetwork(passphrase: fixture.passphrase),
                "\(name): unrecognised passphrase"
            )
            XCTAssertEqual(
                envelope.transaction.hash(network: network).hexString,
                fixture.hash,
                "\(name): transaction hash differs — signatures would be rejected"
            )
        }
    }

    /// The network id is inside the hash, so the same transaction has a
    /// different hash on each network. This is what stops a signature
    /// collected on testnet from being replayed against real funds.
    func test_theSameTransaction_hashesDifferentlyOnEachNetwork() throws {
        let envelope = try envelope(for: "payment_native")
        XCTAssertNotEqual(
            envelope.transaction.hash(network: .testnet),
            envelope.transaction.hash(network: .publicNet)
        )
    }

    // MARK: - 3: building from scratch reproduces the reference

    func test_createAccount_builtFromScratch_matchesTheReference() throws {
        let transaction = try StellarTransaction(
            sourceAccount: account("src"),
            fee: 100,
            sequenceNumber: 101,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 1_893_456_000),
            operations: [
                StellarOperation(body: .createAccount(
                    destination: try account("dst"),
                    startingBalance: try StellarAmount(decimalString: "100.5")
                )),
            ]
        )
        assertMatches(transaction, "create_account")
    }

    func test_payment_inEachAssetWidth_matchesTheReference() throws {
        let native = try payment(asset: .native, amount: "10.0000001")
        assertMatches(native, "payment_native")

        let short = try StellarAsset(code: "USDC", issuer: try account("issuer"))
        assertMatches(try payment(asset: short, amount: "1"), "payment_alphanum4")

        let long = try StellarAsset(code: "LONGASSET123", issuer: try account("issuer"))
        assertMatches(try payment(asset: long, amount: "0.0000001"), "payment_alphanum12")
    }

    func test_changeTrust_atTheMaximumLimit_matchesTheReference() throws {
        let transaction = try StellarTransaction(
            sourceAccount: account("src"),
            fee: 100,
            sequenceNumber: 101,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 1_893_456_000),
            operations: [
                StellarOperation(body: .changeTrust(
                    asset: try StellarAsset(code: "USDC", issuer: try account("issuer")),
                    limit: .max
                )),
            ]
        )
        assertMatches(transaction, "change_trust")
    }

    func test_setOptions_addingASigner_matchesTheReference() throws {
        let fields = SetOptionsFields(
            signer: StellarSigner(key: try account("co1"), weight: 1)
        )
        assertMatches(try setOptions(fields), "set_options_signer")
    }

    func test_setOptions_droppingTheMasterWeight_matchesTheReference() throws {
        let fields = SetOptionsFields(
            masterWeight: 0,
            lowThreshold: 1,
            mediumThreshold: 2,
            highThreshold: 3
        )
        assertMatches(try setOptions(fields), "set_options_lockdown")
    }

    /// The shape treasury creation actually uses: one envelope that
    /// funds the account, adds every co-signer, and drops the master
    /// weight to zero — with per-operation source accounts, which is the
    /// part that makes it possible at all.
    func test_treasuryCreation_asOneAtomicEnvelope_matchesTheReference() throws {
        let treasury = try account("treasury")
        let transaction = try StellarTransaction(
            sourceAccount: account("src"),
            fee: 400,
            sequenceNumber: 101,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 1_893_456_000),
            operations: [
                StellarOperation(body: .createAccount(
                    destination: treasury,
                    startingBalance: try StellarAmount(decimalString: "5")
                )),
                StellarOperation(sourceAccount: treasury, body: .setOptions(
                    SetOptionsFields(signer: StellarSigner(key: try account("co1"), weight: 1))
                )),
                StellarOperation(sourceAccount: treasury, body: .setOptions(
                    SetOptionsFields(signer: StellarSigner(key: try account("co2"), weight: 1))
                )),
                StellarOperation(sourceAccount: treasury, body: .setOptions(
                    SetOptionsFields(
                        masterWeight: 0,
                        lowThreshold: 1,
                        mediumThreshold: 2,
                        highThreshold: 2
                    )
                )),
            ]
        )
        assertMatches(transaction, "treasury_creation")
    }

    func test_memos_matchTheReference() throws {
        assertMatches(try payment(memo: .text("treasury")), "memo_text")
        assertMatches(try payment(memo: .id(42)), "memo_id")
    }

    func test_aTransactionWithoutTimeBounds_matchesTheReference() throws {
        assertMatches(try payment(timeBounds: nil), "no_timebounds")
    }

    // MARK: - Signatures

    /// Signatures made by the reference implementation verify against
    /// the hash this codec computes — the two agree on what was signed.
    func test_referenceSignatures_verifyAgainstOurHash() throws {
        let signed = try envelope(for: "signed_two")
        XCTAssertEqual(signed.signatures.count, 2)

        let src = try account("src")
        let co1 = try account("co1")
        XCTAssertTrue(signed.hasSignature(from: src, network: .testnet))
        XCTAssertTrue(signed.hasSignature(from: co1, network: .testnet))

        // The unsigned twin of the same transaction — what a proposal
        // holds before anyone acts on it.
        var unsigned = TransactionEnvelope(transaction: signed.transaction)
        let adopted = unsigned.harvestSignatures(
            from: signed,
            candidates: [src, co1],
            network: .testnet
        )
        XCTAssertEqual(Set(adopted), [src, co1])
        XCTAssertEqual(unsigned.base64XDR, signed.base64XDR)
    }

    /// The property the external-signing path rests on: a wallet that
    /// returns a correctly-signed envelope for a *different* transaction
    /// contributes nothing. Its body is discarded and its signatures
    /// fail against the hash this device computed.
    func test_signaturesOverADifferentTransaction_areNotAdopted() throws {
        let signed = try envelope(for: "signed_two")
        let ours = try payment(amount: "999")
        var proposal = TransactionEnvelope(transaction: ours)

        let adopted = proposal.harvestSignatures(
            from: signed,
            candidates: [try account("src"), try account("co1")],
            network: .testnet
        )

        XCTAssertTrue(adopted.isEmpty, "a signature over other bytes must not count")
        XCTAssertTrue(proposal.signatures.isEmpty)
        // And the substituted amount did not survive either.
        guard case .payment(_, _, let amount) = proposal.transaction.operations[0].body else {
            return XCTFail("expected a payment")
        }
        XCTAssertEqual(amount.decimalString, "999")
    }

    /// A signature valid for the right transaction but made by someone
    /// nobody declared carries no weight on-chain, so it is dropped
    /// rather than stored.
    func test_aSignatureFromAnUndeclaredSigner_isNotAdopted() throws {
        let signed = try envelope(for: "signed_two")
        var proposal = TransactionEnvelope(transaction: signed.transaction)

        let adopted = proposal.harvestSignatures(
            from: signed,
            candidates: [try account("dst")], // never signed, and isn't a signer
            network: .testnet
        )

        XCTAssertTrue(adopted.isEmpty)
        XCTAssertTrue(proposal.signatures.isEmpty)
    }

    func test_theSameSignature_arrivingTwice_isCountedOnce() throws {
        let signed = try envelope(for: "signed_two")
        let src = try account("src")
        var proposal = TransactionEnvelope(transaction: signed.transaction)

        _ = proposal.harvestSignatures(from: signed, candidates: [src], network: .testnet)
        let second = proposal.harvestSignatures(from: signed, candidates: [src], network: .testnet)

        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(proposal.signatures.count, 1)
    }

    // MARK: - Helpers

    private func envelope(for name: String) throws -> TransactionEnvelope {
        try TransactionEnvelope(base64XDR: XCTUnwrap(fixtures.cases[name]).xdr)
    }

    private func payment(
        asset: StellarAsset = .native,
        amount: String = "1",
        memo: StellarMemo = .none,
        timeBounds: StellarTimeBounds? = StellarTimeBounds(minTime: 0, maxTime: 1_893_456_000)
    ) throws -> StellarTransaction {
        try StellarTransaction(
            sourceAccount: account("src"),
            fee: 100,
            sequenceNumber: 101,
            timeBounds: timeBounds,
            memo: memo,
            operations: [
                StellarOperation(body: .payment(
                    destination: try account("dst"),
                    asset: asset,
                    amount: try StellarAmount(decimalString: amount)
                )),
            ]
        )
    }

    private func setOptions(_ fields: SetOptionsFields) throws -> StellarTransaction {
        try StellarTransaction(
            sourceAccount: account("src"),
            fee: 100,
            sequenceNumber: 101,
            timeBounds: StellarTimeBounds(minTime: 0, maxTime: 1_893_456_000),
            operations: [StellarOperation(body: .setOptions(fields))]
        )
    }

    private func assertMatches(
        _ transaction: StellarTransaction,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let fixture = fixtures.cases[name] else {
            return XCTFail("no fixture named '\(name)'", file: file, line: line)
        }
        let envelope = TransactionEnvelope(transaction: transaction)
        XCTAssertEqual(envelope.base64XDR, fixture.xdr, "\(name)", file: file, line: line)
        guard let network = StellarNetwork(passphrase: fixture.passphrase) else {
            return XCTFail("\(name): unrecognised passphrase", file: file, line: line)
        }
        XCTAssertEqual(
            transaction.hash(network: network).hexString,
            fixture.hash,
            "\(name)",
            file: file,
            line: line
        )
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
