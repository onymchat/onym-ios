import CryptoKit
import Foundation
import OnymPush
import Security

/// Signs push registrations with a key that belongs to the *device*,
/// not to any identity: a random Ed25519 key generated on first use
/// and kept in the Keychain, used for push and nothing else.
///
/// Why not sign with the current identity's key (the moderation
/// signer's shape): registrations refresh every 7 days, and whichever
/// persona is current would sign the refresh — successive registers
/// for the same device token signed by different persona keys would
/// let the push backend link those persona keys to each other. The
/// backend verifies the key and discards it, so *any* key
/// authenticates the session; a per-install random key carries zero
/// identity linkage and never rotates with persona switches. It also
/// keeps the register payload's `userKey` field free of identity
/// material, so Settings can state honestly what leaves the device.
///
/// Keychain posture matches `KeychainIntroKeyStore`:
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — one cached
/// unlock per device, no iCloud Keychain sync, no encrypted-backup
/// transfer. Losing the key (reinstall, restore) is harmless: the
/// next launch mints a fresh one and the next register simply
/// authenticates with that.
struct DevicePushSigner: PushSigner {
    /// Keychain service — one fixed item per device.
    static let serviceDefault = "app.onym.ios.push_signing_key"
    static let account = "ed25519"

    private let service: String

    init(testNamespace: String? = nil) {
        if let testNamespace, !testNamespace.isEmpty {
            service = "\(Self.serviceDefault).\(testNamespace)"
        } else {
            service = Self.serviceDefault
        }
    }

    func userKeyID() async throws -> String {
        let key = try loadOrCreateKey()
        let hex = key.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        return "onym:key:\(hex)"
    }

    func sign(_ message: Data) async throws -> Data {
        try loadOrCreateKey().signature(for: message)
    }

    /// Test helper — drop the key so the next use mints a fresh one.
    func wipe() {
        SecItemDelete(query() as CFDictionary)
    }

    // MARK: - Keychain

    private func loadOrCreateKey() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try loadKey() { return existing }
        let fresh = Curve25519.Signing.PrivateKey()
        var add = query()
        add[kSecValueData as String] = fresh.rawRepresentation
        add[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Two callers raced first use. Whoever won, both must sign
            // with the stored key — a register and its follow-up
            // signed by different keys is exactly the churn this type
            // exists to avoid.
            if let stored = try loadKey() { return stored }
        }
        guard status == errSecSuccess else {
            throw DevicePushSignerError.keychain(status)
        }
        return fresh
    }

    private func loadKey() throws -> Curve25519.Signing.PrivateKey? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        // A corrupted blob throws rather than silently minting a new
        // key over a store error.
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

enum DevicePushSignerError: Error {
    case keychain(OSStatus)
}
