import XCTest
@testable import OnymStellar

/// The Horizon wire layer — ~150 lines of pure parsing that had no
/// coverage, in the one file the package reaches a third party with.
///
/// Horizon spells numbers as strings (`"sequence": "12345"`,
/// `"balance": "10.0000000"`) because JavaScript cannot hold an int64
/// or a 7-decimal fixed-point exactly, so every one of these is a place
/// a parse can go wrong quietly.
final class HorizonWireTests: XCTestCase {

    private let account = "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR"
    private let issuer = "GDWUSKGGFDI4FRXK5EBTRECZSVQSSWJHHJOGH6JWG3AUMFFMQ435DIAG"

    // MARK: - Accounts

    func test_anAccount_parsesItsSequenceBalancesSignersAndThresholds() async throws {
        let parsed = try await client(returning: accountJSON()).account(
            try StellarAccountID(accountID: account)
        )
        XCTAssertEqual(parsed.sequenceNumber, 4_294_967_296)
        XCTAssertEqual(parsed.thresholds, HorizonThresholds(low: 1, medium: 2, high: 3))

        XCTAssertEqual(parsed.balances.count, 2)
        XCTAssertEqual(parsed.balances.first?.asset, .native)
        XCTAssertEqual(parsed.balances.first?.balance.decimalString, "100.5")
        XCTAssertEqual(parsed.balances.last?.asset.code, "USDC")
        XCTAssertEqual(parsed.balances.last?.limit?.decimalString, "1000")

        XCTAssertEqual(parsed.signers.count, 1)
        XCTAssertEqual(parsed.signers.first?.weight, 2)
    }

    /// The sequence is an int64 as a string. A `Double` round trip
    /// would lose precision well below its range, so it is parsed as an
    /// integer or not at all.
    func test_aSequenceThatIsNotAnInt64_failsRatherThanBeingApproximated() async throws {
        let json = accountJSON(sequence: "not-a-number")
        await assertThrows(try await client(returning: json).account(
            try StellarAccountID(accountID: account)
        ))
    }

    /// Silently omitting a balance makes the treasury look poorer than
    /// it is — a worse answer than admitting the read failed.
    func test_anUnparseableBalance_failsTheReadRatherThanVanishing() async throws {
        let json = accountJSON(nativeBalance: "1.000000000000")
        await assertThrows(try await client(returning: json).account(
            try StellarAccountID(accountID: account)
        ))
    }

    /// Non-Ed25519 signers are not accounts and cannot be rendered as
    /// co-signers. Dropping them only ever *under*-counts weight, so a
    /// proposal reads short of its threshold rather than falsely ready.
    func test_nonEd25519Signers_areDropped() async throws {
        let json = accountJSON(extraSigner: """
        {"key": "XABC", "weight": 5, "type": "sha256_hash"}
        """)
        let parsed = try await client(returning: json).account(
            try StellarAccountID(accountID: account)
        )
        XCTAssertEqual(parsed.signers.count, 1)
    }

    /// A liquidity-pool share has no row that would tell the truth
    /// about it, so it is dropped — unlike an unparseable amount.
    func test_aPoolShareBalance_isDropped() async throws {
        let json = accountJSON(extraBalance: """
        {"balance": "5.0000000", "asset_type": "liquidity_pool_shares",
         "liquidity_pool_id": "abc"}
        """)
        let parsed = try await client(returning: json).account(
            try StellarAccountID(accountID: account)
        )
        XCTAssertEqual(parsed.balances.count, 2)
    }

    /// On Stellar an account exists only once funded, so 404 is the
    /// ordinary answer for "not created yet" — a state the treasury
    /// flow expects rather than an error condition.
    func test_anUnfundedAccount_readsAsNotFound() async throws {
        let client = client(returning: "{}", status: 404)
        do {
            _ = try await client.account(try StellarAccountID(accountID: account))
            XCTFail("expected accountNotFound")
        } catch let error as HorizonError {
            guard case .accountNotFound = error else {
                return XCTFail("expected accountNotFound, got \(error)")
            }
        }
    }

    /// Clamped where they enter, so the sums downstream are honest.
    ///
    /// The first fix here used `&+`, which is wrapping, not saturating:
    /// three signers at 0x8000_0000 sum to 0x8000_0000, and a set
    /// summing to 2^32 sums to *zero* — a threshold check reading no
    /// weight for a full quorum, which is worse than the crash it was
    /// avoiding. The protocol bounds weight at 255, so the boundary is
    /// the right place to say so.
    func test_signerWeights_areClampedAtTheProtocolCeiling() async throws {
        let json = accountJSON(extraSigner: """
        {"key": "\(issuer)", "weight": 4294967295, "type": "ed25519_public_key"}
        """)
        let parsed = try await client(returning: json).account(
            try StellarAccountID(accountID: account)
        )
        XCTAssertEqual(parsed.signers.map(\.weight).max(), 255)

        // And the sum of a full signer set cannot overflow.
        let total = parsed.weight(of: parsed.signers.map(\.key))
        XCTAssertEqual(total, 255 + 2)
    }

    /// `nil` is documented as "no ceiling", so a limit that failed to
    /// parse must not quietly become one — the same "looks richer than
    /// it is" answer the balance parse throws to avoid.
    func test_anUnparseableTrustlineLimit_failsTheRead() async throws {
        let json = """
        {"sequence": "1", "balances": [
          {"balance": "1.0000000", "limit": "not-a-number",
           "asset_type": "credit_alphanum4", "asset_code": "USDC",
           "asset_issuer": "\(issuer)"}],
         "signers": [], "thresholds": {"low_threshold": 1,
         "med_threshold": 1, "high_threshold": 1}}
        """
        await assertThrows(try await client(returning: json).account(
            try StellarAccountID(accountID: account)
        ))
    }

    func test_absurdSignerWeights_doNotTrap() throws {
        let signer = try StellarAccountID(accountID: account)
        let other = try StellarAccountID(accountID: issuer)
        let heavy = HorizonAccount(
            accountID: signer,
            sequenceNumber: 1,
            balances: [],
            signers: [
                StellarSigner(key: signer, weight: .max),
                StellarSigner(key: other, weight: .max),
            ],
            thresholds: HorizonThresholds(low: 1, medium: 1, high: 1)
        )
        _ = heavy.weight(of: [signer, other])
    }

    // MARK: - Transactions

    func test_aTransactionRecord_parses() async throws {
        let parsed = try await client(returning: transactionsJSON()).transactions(
            for: try StellarAccountID(accountID: account),
            limit: 10
        )
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.hash, "abc123")
        XCTAssertEqual(parsed.first?.feeCharged.decimalString, "0.00001")
        XCTAssertTrue(parsed.first?.successful ?? false)
    }

    /// History is informational, so one record this build cannot read
    /// must not blank the whole list.
    func test_oneUnreadableRecord_doesNotBlankTheList() async throws {
        let json = """
        {"_embedded": {"records": [
          {"hash": "bad", "created_at": "not-a-date", "source_account": "\(account)",
           "successful": true, "fee_charged": "100", "envelope_xdr": "AAAA"},
          {"hash": "good", "created_at": "2026-09-13T10:00:00Z", "source_account": "\(account)",
           "successful": true, "fee_charged": "100", "envelope_xdr": "AAAA"}
        ]}}
        """
        let parsed = try await client(returning: json).transactions(
            for: try StellarAccountID(accountID: account),
            limit: 10
        )
        XCTAssertEqual(parsed.map(\.hash), ["good"])
    }

    // MARK: - Submission

    /// `tx_bad_seq` means somebody else's transaction won the race, and
    /// it needs a different answer from the user than a generic
    /// failure — so the reason codes are extracted, not just the status.
    func test_aRejectedSubmission_carriesTheProtocolsOwnReasonCodes() async throws {
        let json = """
        {"extras": {"result_codes": {"transaction": "tx_failed",
         "operations": ["op_underfunded"]}}}
        """
        let client = client(returning: json, status: 400)
        do {
            _ = try await client.submit(envelope())
            XCTFail("expected a submission failure")
        } catch let error as HorizonError {
            guard case .submissionFailed(let codes, _) = error else {
                return XCTFail("expected submissionFailed, got \(error)")
            }
            XCTAssertEqual(codes, ["tx_failed", "op_underfunded"])
        }
    }

    func test_anAcceptedSubmission_returnsTheHash() async throws {
        let hash = try await client(returning: #"{"hash": "deadbeef"}"#).submit(envelope())
        XCTAssertEqual(hash, "deadbeef")
    }

    func test_networkParameters_parse() async throws {
        let json = #"{"base_fee_in_stroops": 100, "base_reserve_in_stroops": 5000000}"#
        let parameters = try await client(returning: json).networkParameters()
        XCTAssertEqual(parameters.baseFee.stroops, 100)
        XCTAssertEqual(parameters.baseReserve.decimalString, "0.5")
    }

    // MARK: - Helpers

    private func client(returning body: String, status: Int = 200) -> URLSessionHorizonClient {
        StubURLProtocol.body = Data(body.utf8)
        StubURLProtocol.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionHorizonClient(
            baseURL: URL(string: "https://horizon.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func envelope() throws -> TransactionEnvelope {
        TransactionEnvelope(transaction: try StellarTransaction(
            sourceAccount: try StellarAccountID(accountID: account),
            fee: 100,
            sequenceNumber: 1,
            timeBounds: nil,
            operations: [StellarOperation(body: .changeTrust(asset: .native, limit: .max))]
        ))
    }

    private func assertThrows(
        _ expression: @autoclosure () async throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected a throw", file: file, line: line)
        } catch {}
    }

    private func accountJSON(
        sequence: String = "4294967296",
        nativeBalance: String = "100.5000000",
        extraBalance: String? = nil,
        extraSigner: String? = nil
    ) -> String {
        var balances = [
            """
            {"balance": "\(nativeBalance)", "asset_type": "native"}
            """,
            """
            {"balance": "25.0000000", "limit": "1000.0000000",
             "asset_type": "credit_alphanum4", "asset_code": "USDC",
             "asset_issuer": "\(issuer)"}
            """,
        ]
        if let extraBalance { balances.append(extraBalance) }
        var signers = [#"{"key": "\#(account)", "weight": 2, "type": "ed25519_public_key"}"#]
        if let extraSigner { signers.append(extraSigner) }
        return """
        {"sequence": "\(sequence)",
         "balances": [\(balances.joined(separator: ","))],
         "signers": [\(signers.joined(separator: ","))],
         "thresholds": {"low_threshold": 1, "med_threshold": 2, "high_threshold": 3}}
        """
    }

    private func transactionsJSON() -> String {
        """
        {"_embedded": {"records": [
          {"hash": "abc123", "created_at": "2026-09-13T10:00:00Z",
           "source_account": "\(account)", "successful": true,
           "fee_charged": "100", "envelope_xdr": "AAAA"}
        ]}}
        """
    }
}

/// Minimal URLProtocol stub. The app target has one of these; the
/// package can't reach it, and this needs only a body and a status.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
