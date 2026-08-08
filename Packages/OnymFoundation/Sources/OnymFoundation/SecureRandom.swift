import Foundation
import Security

/// Centralised CSPRNG access. Every caller that needs security-grade
/// random bytes routes through here so a `SecRandomCopyBytes` failure
/// surfaces as a thrown error instead of silently leaving the all-zero
/// buffer in place and using it as key material.
///
/// Mirrors the status-checking pattern already used by
/// `OnymNostrSigner.ephemeral()`.
public enum SecureRandom {
    /// Fill and return `count` cryptographically-secure random bytes.
    /// Throws `SecureRandomError.csprngFailed` when the system CSPRNG
    /// reports failure, rather than returning the all-zero buffer.
    public static func bytes(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else {
            throw SecureRandomError.csprngFailed(status: Int(status))
        }
        return buffer
    }

    /// Convenience returning `Data` instead of `[UInt8]`.
    public static func data(_ count: Int) throws -> Data {
        Data(try bytes(count))
    }
}

enum SecureRandomError: LocalizedError {
    case csprngFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case let .csprngFailed(status):
            return "Secure random generation failed (OSStatus \(status))"
        }
    }
}
