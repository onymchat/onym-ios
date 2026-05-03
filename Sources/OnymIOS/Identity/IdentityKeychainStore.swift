import Foundation
import Security

/// Per-identity Keychain store. Each identity gets its own
/// `kSecClassGenericPassword` item under the service name
/// `chat.onym.ios.identity.<uuid>`. Listing identities is a single
/// `SecItemCopyMatching` over that service-name prefix.
///
/// Same `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` policy as
/// the legacy single-slot `KeychainStore` — one cached unlock per
/// device, no iCloud Keychain sync, no encrypted-backup transfer.
///
/// Replaces the singleton `KeychainStore` in PR-2 (the legacy store
/// is left in tree here so PR-1 stays mergeable; the
/// `IdentityRepository` rewrite + call-site cascade lands in PR-2).
struct IdentityKeychainStore: Sendable {
    /// Service-name prefix shared by every per-identity item. Listing
    /// identities walks every item whose service starts with this.
    static let servicePrefix = "chat.onym.ios.identity."

    /// Stable account string used for every item. The discriminator is
    /// the per-identity service suffix; account is constant so reading
    /// back doesn't need to remember it.
    static let account = "current"

    /// Optional injection seam for tests — production uses the default
    /// init which targets the real Keychain. Tests pass a `serviceSuffix`
    /// override that namespaces test runs and lets `wipeAll` clean up
    /// reliably across teardowns.
    let testNamespace: String?

    init(testNamespace: String? = nil) {
        self.testNamespace = testNamespace
    }

    // MARK: - Public API

    /// Every identity currently persisted. Order is keychain-internal
    /// (effectively undefined) — the repository sorts by display name
    /// before showing the picker.
    func list() throws -> [IdentityID] {
        let prefix = servicePrefix(for: testNamespace)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw IdentityError.keychainRead(status)
        }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { attrs in
            guard let service = attrs[kSecAttrService as String] as? String,
                  service.hasPrefix(prefix)
            else { return nil }
            let suffix = String(service.dropFirst(prefix.count))
            return IdentityID(suffix)
        }
    }

    /// Read the secret bundle for `id`. Returns `nil` for
    /// `errSecItemNotFound`; throws for any other keychain error.
    func read(_ id: IdentityID) throws -> StoredSnapshot? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: Self.account,
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

    /// Insert-or-update `snapshot` for `id`. Idempotent.
    func write(_ id: IdentityID, _ snapshot: StoredSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: Self.account,
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

    /// Drop the keychain item for `id`. No-op if it's already gone.
    func wipe(_ id: IdentityID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: id),
            kSecAttrAccount as String: Self.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychainDelete(status)
        }
    }

    /// Drop every per-identity item — used by tests in `tearDown` and
    /// (eventually) the user-facing "reset all identities" flow.
    func wipeAll() throws {
        let prefix = servicePrefix(for: testNamespace)
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecSuccess { return }
            throw IdentityError.keychainRead(status)
        }
        for attrs in items {
            guard let service = attrs[kSecAttrService as String] as? String,
                  service.hasPrefix(prefix)
            else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: Self.account,
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw IdentityError.keychainDelete(deleteStatus)
            }
        }
    }

    // MARK: - Private

    /// Per-identity service name. Tests override the prefix via
    /// `testNamespace` so concurrent test runs don't stomp on each
    /// other's keychain entries.
    private func service(for id: IdentityID) -> String {
        servicePrefix(for: testNamespace) + id.rawValue.uuidString
    }

    /// Returns the prefix used to list/match per-identity items. The
    /// `testNamespace` (when set) is folded into the prefix so a test
    /// can `wipeAll` reliably without touching production identities.
    private func servicePrefix(for namespace: String?) -> String {
        if let namespace, !namespace.isEmpty {
            return "\(Self.servicePrefix)\(namespace)."
        }
        return Self.servicePrefix
    }
}
