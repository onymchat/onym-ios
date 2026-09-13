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
    private var history: [HorizonTransaction] = []
    /// Envelopes handed to `submit`, in order.
    private(set) var submitted: [TransactionEnvelope] = []
    private var submitError: HorizonError?
    private var submitHash = "deadbeef"

    init() {}

    func setAccount(_ account: HorizonAccount) {
        accounts[account.accountID.accountID] = account
    }

    /// When set, `submit` throws this instead of succeeding.
    func setSubmitError(_ error: HorizonError?) { submitError = error }

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
        submitted.append(envelope)
        if let submitError { throw submitError }
        return submitHash
    }

    func networkParameters() async throws -> HorizonNetworkParameters { parameters }
}

/// Deterministic Stellar keys for tests. Seeded so a failure names the
/// same account every run.
enum TreasuryTestKeys {
    static func key(_ seed: UInt8) -> Curve25519.Signing.PrivateKey {
        // swiftlint:disable:next force_try
        try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: seed, count: 32)
        )
    }

    static func account(_ seed: UInt8) -> StellarAccountID {
        // swiftlint:disable:next force_try
        try! StellarAccountID(publicKey: Data(key(seed).publicKey.rawRepresentation))
    }
}
