import CryptoKit
import Foundation
import Security

/// Field-level encryption for at-rest data. AES-256-GCM with a key
/// derived from a Keychain-stored 32-byte root secret via HKDF-SHA256.
///
/// The root secret is generated once on first read and stored in the
/// Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The
/// AES key never sits on disk; only the seed does. Disk forensics with
/// the device locked recovers neither the seed nor the plaintext.
///
/// Independent of `IdentityRepository` by design — anything in the
/// Persistence seam can encrypt/decrypt without taking a dependency on
/// identity.
enum StorageEncryption {
    private static let keychainAccount = "chat.onym.ios.storageRootKey"

    /// Memoised so repeated `encrypt` / `decrypt` calls don't round-trip
    /// to the Keychain. The seed itself never changes for the lifetime
    /// of the install (changing it would orphan every encrypted column).
    private static let cachedRootSecret: Data = loadOrCreateRootSecret()

    /// AES-256 key derived from the root secret. HKDF salt + info pin
    /// the derivation to this specific use ("storage at-rest, v1") so a
    /// future second consumer of the same root secret won't collide.
    static var storageKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: cachedRootSecret),
            salt: Data("chat.onym.ios.storage".utf8),
            info: Data("local-storage-v1".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt arbitrary bytes. Output is the AES-GCM `combined` form:
    /// `nonce (12B) || ciphertext || tag (16B)`. Decryption is the
    /// inverse — `decrypt` accepts that exact byte shape.
    static func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: storageKey)
        guard let combined = sealed.combined else {
            throw StorageEncryptionError.encryptionFailed
        }
        return combined
    }

    /// Encrypt a UTF-8 string.
    static func encrypt(_ string: String) throws -> Data {
        try encrypt(Data(string.utf8))
    }

    /// Decrypt bytes produced by `encrypt(_:)`. Throws on tampered or
    /// truncated input (AES-GCM tag verification fails).
    static func decrypt(_ combined: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: storageKey)
    }

    /// Decrypt to a UTF-8 string.
    static func decryptString(_ combined: Data) throws -> String {
        let data = try decrypt(combined)
        guard let string = String(data: data, encoding: .utf8) else {
            throw StorageEncryptionError.decodingFailed
        }
        return string
    }

    // MARK: - Keychain

    private static func loadOrCreateRootSecret() -> Data {
        if let existing = loadFromKeychain() {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let secret = Data(bytes)
        saveToKeychain(secret)
        return secret
    }

    private static func loadFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return data
        }
        return nil
    }

    private static func saveToKeychain(_ data: Data) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }
}

enum StorageEncryptionError: LocalizedError {
    case encryptionFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Failed to encrypt data for storage"
        case .decodingFailed: return "Failed to decode decrypted data"
        }
    }
}
