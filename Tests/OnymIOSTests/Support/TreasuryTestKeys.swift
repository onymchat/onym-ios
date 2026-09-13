import CryptoKit
import Foundation
import OnymStellar

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
