import CryptoKit
import Foundation
import OnymStellar

/// Canned Horizon, for tests that need an account to exist without a
/// network.
///
/// Everything is set through a method rather than a `var`: this is an
/// actor, so a cross-actor write to a property is not available to
/// callers anyway, and an earlier version documented "settable state"
/// it did not have.
///
/// Deliberately dumb — it returns what it was given. `LedgerHorizon` in
/// `TreasuryE2ETests` is the one that *applies* transactions, and the
/// two exist for different jobs.
actor FakeHorizonClient: HorizonClient {
    private var accounts: [String: HorizonAccount] = [:]
    private var parameters = HorizonNetworkParameters(
        baseFee: StellarAmount(stroops: 100),
        baseReserve: StellarAmount(stroops: 5_000_000)
    )
    /// Applied transactions this fake will report. Empty unless a test
    /// sets them — `LedgerHorizon` is the one that derives history from
    /// what was submitted.
    private var history: [HorizonTransaction] = []
    private var submitError: HorizonError?

    init() {}

    func setAccount(_ account: HorizonAccount) {
        accounts[account.accountID.accountID] = account
    }

    /// When set, `submit` throws this instead of succeeding.
    func setSubmitError(_ error: HorizonError?) { submitError = error }

    func setTransactions(_ transactions: [HorizonTransaction]) { history = transactions }

    func account(_ id: StellarAccountID) async throws -> HorizonAccount {
        guard let account = accounts[id.accountID] else {
            throw HorizonError.accountNotFound(id.accountID)
        }
        return account
    }

    func transactions(for id: StellarAccountID, limit: Int) async throws -> [HorizonTransaction] {
        history
    }

    func submit(_ envelope: TransactionEnvelope) async throws -> String {
        if let submitError { throw submitError }
        return envelope.transaction.hash(network: .testnet).hexString
    }

    func networkParameters() async throws -> HorizonNetworkParameters { parameters }
}
