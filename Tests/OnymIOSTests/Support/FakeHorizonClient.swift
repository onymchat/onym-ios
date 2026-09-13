import CryptoKit
import Foundation
import OnymStellar

/// Canned Horizon, for tests that need an account to exist without a
/// network. Mirrors `FakeInboxTransport`'s shape: an actor with
/// settable state and recorded calls.
actor FakeHorizonClient: HorizonClient {
    var accounts: [String: HorizonAccount] = [:]
    var parameters = HorizonNetworkParameters(
        baseFee: StellarAmount(stroops: 100),
        baseReserve: StellarAmount(stroops: 5_000_000)
    )
    var transactions: [HorizonTransaction] = []
    /// Envelopes handed to `submit`, in order.
    private(set) var submitted: [TransactionEnvelope] = []
    /// When set, `submit` throws this instead of succeeding.
    var submitError: HorizonError?
    var submitHash = "deadbeef"

    init() {}

    func setAccount(_ account: HorizonAccount) {
        accounts[account.accountID.accountID] = account
    }

    func setSubmitError(_ error: HorizonError?) { submitError = error }

    func account(_ id: StellarAccountID) async throws -> HorizonAccount {
        guard let account = accounts[id.accountID] else {
            throw HorizonError.accountNotFound(id.accountID)
        }
        return account
    }

    func transactions(for id: StellarAccountID, limit: Int) async throws -> [HorizonTransaction] {
        transactions
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
