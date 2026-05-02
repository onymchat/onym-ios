import Foundation
import Security

/// Atomic, single-blob persistence for the on-device identity secrets.
///
/// One Keychain item (`kSecClassGenericPassword`) holds the JSON-encoded
/// `StoredSnapshot` — entropy + both secret keys in a single record. Any
/// mutation is one `SecItemUpdate` (or `SecItemAdd`) call: there is no
/// intermediate state where one secret has been written and another has
/// not, so the partial-failure cleanup the reference impl does for its
/// three-item layout is unnecessary here.
///
/// Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the
/// secrets survive reboot but never leave the device (no iCloud Keychain
/// sync, no device-to-device transfer in encrypted backups).
struct StoredSnapshot: Codable, Sendable, Equatable {
    /// 16 bytes (128-bit BIP39 entropy). `nil` only if the identity was
    /// imported from raw key material without an associated mnemonic — not
    /// currently produced by the repository, but tolerated on read so the
    /// shape stays forward-compatible with a future "import raw secret" path.
    let entropy: Data?
    /// 32-byte secp256k1 secret key for Nostr signing.
    let nostrSecretKey: Data
    /// 32-byte BLS12-381 Fr scalar for SEP group membership.
    let blsSecretKey: Data
}

struct KeychainStore: Sendable {
    static let `default` = KeychainStore(
        service: "chat.onym.ios.identity",
        account: "current"
    )

    let service: String
    let account: String

    func load() throws -> StoredSnapshot? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw IdentityError.keychainRead(status)
        }
        do {
            return try JSONDecoder().decode(StoredSnapshot.self, from: data)
        } catch {
            throw IdentityError.storedSnapshotInvalid(reason: "decode failed: \(error)")
        }
    }

    func save(_ snapshot: StoredSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw IdentityError.keychainWrite(addStatus)
            }
            return
        }
        throw IdentityError.keychainWrite(updateStatus)
    }

    func wipe() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychainDelete(status)
        }
    }
}
