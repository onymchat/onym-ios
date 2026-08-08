import Foundation
import Security

/// Atomic, single-blob persistence for the on-device identity secrets.
/// One Keychain item per identity holds the JSON-encoded
/// `StoredSnapshot` (entropy + both secret keys + display name) — any
/// mutation is one `SecItemUpdate` (or `SecItemAdd`) call so there's
/// no partial-write window.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the default
/// for every item written through this store.
public struct StoredSnapshot: Codable, Sendable, Equatable {
    /// Display name surfaced in the identity picker. Optional because
    /// the on-disk format has historically allowed nameless imports;
    /// `IdentityRepository` synthesises a default ("Identity 1", …)
    /// when nil.
    var name: String?
    /// 16 bytes (128-bit BIP39 entropy). `nil` only if the identity
    /// was imported from raw key material without an associated
    /// mnemonic — kept for forward-compat with a future "import raw
    /// secret" path.
    public let entropy: Data?
    /// 32-byte secp256k1 secret key for Nostr signing.
    public let nostrSecretKey: Data
    /// 32-byte BLS12-381 Fr scalar for SEP group membership.
    public let blsSecretKey: Data

    public init(name: String? = nil, entropy: Data?, nostrSecretKey: Data, blsSecretKey: Data) {
        self.name = name
        self.entropy = entropy
        self.nostrSecretKey = nostrSecretKey
        self.blsSecretKey = blsSecretKey
    }
}

/// Per-identity Keychain store. Each identity gets its own
/// `kSecClassGenericPassword` item under the service name
/// `app.onym.ios.identity.<uuid>`. Listing identities is a single
/// `SecItemCopyMatching` over that service-name prefix.
///
/// Same `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` policy as
/// the legacy single-slot `KeychainStore` — one cached unlock per
/// device, no iCloud Keychain sync, no encrypted-backup transfer.
///
/// Replaces the singleton `KeychainStore` in PR-2 (the legacy store
/// is left in tree here so PR-1 stays mergeable; the
/// `IdentityRepository` rewrite + call-site cascade lands in PR-2).
public struct IdentityKeychainStore: Sendable {
    /// Service-name prefix shared by every per-identity item. Listing
    /// identities walks every item whose service starts with this.
    static let servicePrefix = "app.onym.ios.identity."

    /// Stable account string used for every item. The discriminator is
    /// the per-identity service suffix; account is constant so reading
    /// back doesn't need to remember it.
    static let account = "current"

    /// Service-name prefix for quarantined items. Deliberately NOT an
    /// extension of `servicePrefix` so `list()`/`read()` can never see
    /// a quarantined identity. Items land here instead of being
    /// destroyed when `reconcileFreshInstall()` decides they're
    /// orphans of a deleted install — that verdict rests on soft
    /// UserDefaults signals, so the key material must survive it.
    static let quarantineServicePrefix = "app.onym.ios.identity-quarantine."

    /// Optional injection seam for tests — production uses the default
    /// init which targets the real Keychain. Tests pass a `serviceSuffix`
    /// override that namespaces test runs and lets `wipeAll` clean up
    /// reliably across teardowns.
    let testNamespace: String?

    public init(testNamespace: String? = nil) {
        self.testNamespace = testNamespace
    }

    // MARK: - Public API

    /// Every identity currently persisted. Order is keychain-internal
    /// (effectively undefined) — the repository sorts by display name
    /// before showing the picker.
    public func list() throws -> [IdentityID] {
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
    public func read(_ id: IdentityID) throws -> StoredSnapshot? {
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
    public func write(_ id: IdentityID, _ snapshot: StoredSnapshot) throws {
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
    public func wipe(_ id: IdentityID) throws {
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

    /// Drop every per-identity item, active AND quarantined — used by
    /// tests in `tearDown` and (eventually) the user-facing "reset all
    /// identities" flow.
    public func wipeAll() throws {
        let prefixes = [
            servicePrefix(for: testNamespace),
            quarantinePrefix(for: testNamespace),
        ]
        for attrs in try listAllItems() {
            guard let service = attrs[kSecAttrService as String] as? String,
                  prefixes.contains(where: { service.hasPrefix($0) })
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

    /// Move every active per-identity item into the quarantine
    /// namespace instead of destroying it. Quarantined items are
    /// invisible to `list()`/`read()` (the picker, the inbox fan-out)
    /// but the secret material stays at rest, so a wrong "fresh
    /// install" verdict is recoverable rather than fatal.
    public func quarantineAll() throws {
        let activePrefix = servicePrefix(for: testNamespace)
        let targetPrefix = quarantinePrefix(for: testNamespace)
        for attrs in try listAllItems() {
            guard let service = attrs[kSecAttrService as String] as? String,
                  service.hasPrefix(activePrefix)
            else { continue }
            let suffix = String(service.dropFirst(activePrefix.count))
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: Self.account,
            ]
            let rename: [String: Any] = [
                kSecAttrService as String: targetPrefix + suffix,
            ]
            let status = SecItemUpdate(query as CFDictionary, rename as CFDictionary)
            if status == errSecDuplicateItem {
                // A previous quarantine of this same id already holds a
                // copy — keeping it is enough; drop the active twin.
                let deleteStatus = SecItemDelete(query as CFDictionary)
                guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                    throw IdentityError.keychainDelete(deleteStatus)
                }
                continue
            }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw IdentityError.keychainWrite(status)
            }
        }
    }

    /// Every quarantined identity id — surfaced so a future recovery /
    /// support flow can offer them back to the user.
    public func listQuarantined() throws -> [IdentityID] {
        let prefix = quarantinePrefix(for: testNamespace)
        return try listAllItems().compactMap { attrs in
            guard let service = attrs[kSecAttrService as String] as? String,
                  service.hasPrefix(prefix)
            else { return nil }
            return IdentityID(String(service.dropFirst(prefix.count)))
        }
    }

    // MARK: - Private

    /// One `SecItemCopyMatching` over every generic-password item;
    /// callers filter by service prefix. Returns `[]` when the
    /// keychain is empty.
    private func listAllItems() throws -> [[String: Any]] {
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
        return (result as? [[String: Any]]) ?? []
    }

    /// Per-identity service name. Tests override the prefix via
    /// `testNamespace` so concurrent test runs don't stomp on each
    /// other's keychain entries.
    private func service(for id: IdentityID) -> String {
        servicePrefix(for: testNamespace) + id.rawValue.uuidString
    }

    /// Quarantine analogue of `servicePrefix(for:)` — same namespacing
    /// rule so tests quarantine into their own sandbox too.
    private func quarantinePrefix(for namespace: String?) -> String {
        if let namespace, !namespace.isEmpty {
            return "\(Self.quarantineServicePrefix)\(namespace)."
        }
        return Self.quarantineServicePrefix
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
