import Foundation

/// Horizon over `URLSession`. Same shape as
/// `URLSessionSEPContractTransport`: an endpoint, an injected session,
/// a status guard, and typed errors.
///
/// Horizon's JSON spells numbers as strings (`"sequence": "12345"`,
/// `"balance": "10.0000000"`) because JavaScript cannot hold an int64
/// or a 7-decimal fixed-point exactly. Those strings are parsed with
/// `Int64` and `StellarAmount` rather than `Double` for the same
/// reason — see `StellarAmount`.
public struct URLSessionHorizonClient: HorizonClient {
    public static let testnetURL = URL(string: "https://horizon-testnet.stellar.org")!
    public static let publicURL = URL(string: "https://horizon.stellar.org")!

    let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public init(network: StellarNetwork, session: URLSession = .shared) {
        self.init(
            baseURL: network == .testnet ? Self.testnetURL : Self.publicURL,
            session: session
        )
    }

    // MARK: - HorizonClient

    public func account(_ id: StellarAccountID) async throws -> HorizonAccount {
        let wire: AccountWire = try await get("/accounts/\(id.accountID)", notFound: id.accountID)
        return try wire.domain(accountID: id)
    }

    public func transactions(
        for id: StellarAccountID,
        limit: Int
    ) async throws -> [HorizonTransaction] {
        let path = "/accounts/\(id.accountID)/transactions"
            + "?order=desc&limit=\(limit)&include_failed=true"
        let page: PageWire<TransactionWire> = try await get(path, notFound: id.accountID)
        // A record that fails to convert is dropped rather than failing
        // the page: history is informational, and one operation type
        // this build cannot name should not blank the whole list.
        return page.embedded.records.compactMap { try? $0.domain() }
    }

    public func submit(_ envelope: TransactionEnvelope) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("transactions"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        // Form-encoded, so the base64 must be escaped: an unescaped `+`
        // is decoded as a space by the form parser on the other side.
        let escaped = envelope.base64XDR.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? envelope.base64XDR
        request.httpBody = Data("tx=\(escaped)".utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
        guard (200..<300).contains(status) else {
            // Horizon returns the protocol's own reason codes in a
            // problem document. They are worth extracting because
            // `tx_bad_seq` (someone else used the sequence number) and
            // `tx_failed` with `op_underfunded` need different things
            // from the user, and the HTTP status says only "400".
            let codes = (try? JSONDecoder().decode(SubmitErrorWire.self, from: data))?
                .extras?.resultCodes?.flattened ?? []
            throw HorizonError.submissionFailed(resultCodes: codes, body: body)
        }
        guard let result = try? JSONDecoder().decode(SubmitSuccessWire.self, from: data) else {
            throw HorizonError.decodeFailure(body)
        }
        return result.hash
    }

    public func networkParameters() async throws -> HorizonNetworkParameters {
        let wire: RootWire = try await get("/", notFound: "root")
        return HorizonNetworkParameters(
            baseFee: StellarAmount(stroops: wire.baseFeeInStroops),
            baseReserve: StellarAmount(stroops: wire.baseReserveInStroops)
        )
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, notFound: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw HorizonError.decodeFailure("bad path \(path)")
        }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status != 404 else {
            // On Stellar an account exists only once it has been funded,
            // so 404 is the ordinary answer for "not created yet" — a
            // state the treasury flow expects, not an error condition.
            throw HorizonError.accountNotFound(notFound)
        }
        guard (200..<300).contains(status) else {
            throw HorizonError.invalidResponse(
                statusCode: status,
                body: String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HorizonError.decodeFailure(String(describing: error))
        }
    }
}

// MARK: - Wire shapes

private struct PageWire<Record: Decodable>: Decodable {
    struct Embedded: Decodable { let records: [Record] }
    let embedded: Embedded

    enum CodingKeys: String, CodingKey { case embedded = "_embedded" }
}

private struct RootWire: Decodable {
    let baseFeeInStroops: Int64
    let baseReserveInStroops: Int64

    enum CodingKeys: String, CodingKey {
        case baseFeeInStroops = "base_fee_in_stroops"
        case baseReserveInStroops = "base_reserve_in_stroops"
    }
}

private struct AccountWire: Decodable {
    struct Balance: Decodable {
        let balance: String
        let limit: String?
        let assetType: String
        let assetCode: String?
        let assetIssuer: String?

        enum CodingKeys: String, CodingKey {
            case balance, limit
            case assetType = "asset_type"
            case assetCode = "asset_code"
            case assetIssuer = "asset_issuer"
        }
    }

    struct Signer: Decodable {
        let key: String
        let weight: UInt32
        let type: String
    }

    struct Thresholds: Decodable {
        let lowThreshold: UInt32
        let medThreshold: UInt32
        let highThreshold: UInt32

        enum CodingKeys: String, CodingKey {
            case lowThreshold = "low_threshold"
            case medThreshold = "med_threshold"
            case highThreshold = "high_threshold"
        }
    }

    let sequence: String
    let balances: [Balance]
    let signers: [Signer]
    let thresholds: Thresholds

    func domain(accountID: StellarAccountID) throws -> HorizonAccount {
        guard let sequenceNumber = Int64(sequence) else {
            throw HorizonError.decodeFailure("sequence '\(sequence)' is not an Int64")
        }
        return HorizonAccount(
            accountID: accountID,
            sequenceNumber: sequenceNumber,
            balances: balances.compactMap { wire in
                guard let amount = try? StellarAmount(decimalString: wire.balance) else {
                    return nil
                }
                let asset: StellarAsset
                if wire.assetType == "native" {
                    asset = .native
                } else if let code = wire.assetCode,
                          let issuer = wire.assetIssuer,
                          let account = try? StellarAccountID(accountID: issuer),
                          let credit = try? StellarAsset(code: code, issuer: account) {
                    asset = credit
                } else {
                    // Liquidity-pool shares land here. Dropped rather
                    // than guessed at — the treasury screen has no row
                    // that would tell the truth about one.
                    return nil
                }
                return HorizonBalance(
                    asset: asset,
                    balance: amount,
                    limit: wire.limit.flatMap { try? StellarAmount(decimalString: $0) }
                )
            },
            // Non-Ed25519 signers (pre-auth, hash-x) are dropped: they
            // are not accounts, `StellarAccountID` cannot hold one, and
            // showing them as co-signers would misdescribe who controls
            // the treasury. Their weight is therefore missing from
            // `weight(of:)`, which only ever under-counts — a proposal
            // looks short of the threshold rather than falsely ready.
            signers: signers.compactMap { wire in
                guard wire.type == "ed25519_public_key",
                      let key = try? StellarAccountID(accountID: wire.key)
                else { return nil }
                return StellarSigner(key: key, weight: wire.weight)
            },
            thresholds: HorizonThresholds(
                low: thresholds.lowThreshold,
                medium: thresholds.medThreshold,
                high: thresholds.highThreshold
            )
        )
    }
}

private struct TransactionWire: Decodable {
    let hash: String
    let createdAt: String
    let sourceAccount: String
    let successful: Bool
    let feeCharged: String
    let envelopeXDR: String

    enum CodingKeys: String, CodingKey {
        case hash, successful
        case createdAt = "created_at"
        case sourceAccount = "source_account"
        case feeCharged = "fee_charged"
        case envelopeXDR = "envelope_xdr"
    }

    func domain() throws -> HorizonTransaction {
        guard let date = ISO8601DateFormatter().date(from: createdAt) else {
            throw HorizonError.decodeFailure("created_at '\(createdAt)'")
        }
        guard let fee = Int64(feeCharged) else {
            throw HorizonError.decodeFailure("fee_charged '\(feeCharged)'")
        }
        return HorizonTransaction(
            hash: hash,
            ledgerCloseTime: date,
            sourceAccount: try StellarAccountID(accountID: sourceAccount),
            successful: successful,
            feeCharged: StellarAmount(stroops: fee),
            envelopeXDR: envelopeXDR
        )
    }
}

private struct SubmitSuccessWire: Decodable {
    let hash: String
}

private struct SubmitErrorWire: Decodable {
    struct Extras: Decodable {
        struct ResultCodes: Decodable {
            let transaction: String?
            let operations: [String]?

            var flattened: [String] {
                (transaction.map { [$0] } ?? []) + (operations ?? [])
            }
        }
        let resultCodes: ResultCodes?

        enum CodingKeys: String, CodingKey { case resultCodes = "result_codes" }
    }
    let extras: Extras?
}
