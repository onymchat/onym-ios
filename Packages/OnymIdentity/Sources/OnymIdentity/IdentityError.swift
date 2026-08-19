import Foundation

public enum IdentityError: Error, Equatable {
    case keychainRead(OSStatus)
    case keychainWrite(OSStatus)
    case keychainDelete(OSStatus)
    case storedSnapshotInvalid(reason: String)
    case invalidMnemonic
    case identityNotLoaded
    /// No stored identity's Stellar public key matches the requested
    /// hex — it was removed, or quarantined by a fresh-install verdict.
    case noIdentityForKey(String)
    /// This identity was imported from raw key material, so it has no
    /// BIP39 seed and nothing can be derived from one for it. Callers
    /// that need a seed-scoped key must refuse rather than substitute:
    /// a key derived from something else could not be recovered from the
    /// recovery phrase, which is the only reason the key exists.
    case noRecoveryPhrase
    case sdkFailure(String)
}

extension IdentityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .keychainRead(status):
            return "Keychain read failed (status \(status))"
        case let .keychainWrite(status):
            return "Keychain write failed (status \(status))"
        case let .keychainDelete(status):
            return "Keychain delete failed (status \(status))"
        case let .storedSnapshotInvalid(reason):
            return "Stored identity is invalid: \(reason)"
        case .invalidMnemonic:
            return "Invalid recovery phrase"
        case .identityNotLoaded:
            return "No identity is loaded — bootstrap or restore first"
        case let .noIdentityForKey(hex):
            return "No stored identity has the public key \(hex)"
        case .noRecoveryPhrase:
            return "This identity has no recovery phrase, so no seed-derived key exists for it"
        case let .sdkFailure(message):
            return "OnymSDK call failed: \(message)"
        }
    }
}
