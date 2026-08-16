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
        case let .sdkFailure(message):
            return "OnymSDK call failed: \(message)"
        }
    }
}
