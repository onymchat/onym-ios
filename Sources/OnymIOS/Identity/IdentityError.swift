import Foundation

enum IdentityError: Error, Equatable {
    case keychainRead(OSStatus)
    case keychainWrite(OSStatus)
    case keychainDelete(OSStatus)
    case storedSnapshotInvalid(reason: String)
    case invalidMnemonic
    case sdkFailure(String)
}

extension IdentityError: LocalizedError {
    var errorDescription: String? {
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
        case let .sdkFailure(message):
            return "OnymSDK call failed: \(message)"
        }
    }
}
