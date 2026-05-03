import Foundation
import Security

/// Production `IntroKeyStore` backed by a single Keychain item per
/// device. Whole-blob persistence — every mutation rewrites the
/// JSON-encoded list. Intro privkeys are tiny (32B each) and the
/// realistic count is dozens, not thousands, so the rewrite cost
/// is negligible and we get atomicity for free (one
/// `SecItemUpdate` / `SecItemAdd` per call).
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` matches the
/// existing `IdentityKeychainStore` policy: one cached unlock per
/// device, no iCloud Keychain sync, no encrypted-backup transfer.
/// A backup-extracted blob is unreadable on the restoring device.
///
/// Mirrors onym-android's `EncryptedPrefsIntroKeyStore` —
/// whole-blob, JSON-serialized, base64-encoded `Data` fields.
actor KeychainIntroKeyStore: IntroKeyStore {

    /// Keychain service — one fixed item across the device.
    static let serviceDefault = "chat.onym.ios.intro_keys"
    static let account = "blob"

    private let service: String
    /// Per-owner subscriber continuations. Mutations re-emit the
    /// filtered+sorted snapshot to every subscriber whose owner
    /// matches.
    private var continuations: [IdentityID: [UUID: AsyncStream<[IntroKeyEntry]>.Continuation]] = [:]

    init(testNamespace: String? = nil) {
        if let testNamespace, !testNamespace.isEmpty {
            self.service = "\(Self.serviceDefault).\(testNamespace)"
        } else {
            self.service = Self.serviceDefault
        }
    }

    // MARK: - IntroKeyStore

    func save(_ entry: IntroKeyEntry) async {
        var current = loadAll()
        // Idempotent on introPublicKey.
        current.removeAll { $0.introPub == entry.introPublicKey }
        current.append(StoredIntroKey(from: entry))
        writeAll(current)
        publish(forOwner: entry.ownerIdentityID)
    }

    func find(introPublicKey: Data) async -> IntroKeyEntry? {
        loadAll()
            .first { $0.introPub == introPublicKey }
            .flatMap { $0.toEntry() }
    }

    func listForOwner(_ ownerIdentityID: IdentityID) async -> [IntroKeyEntry] {
        loadAll()
            .filter { $0.ownerIdentityID == ownerIdentityID.rawValue.uuidString }
            .sorted { $0.createdAtMillis > $1.createdAtMillis }
            .compactMap { $0.toEntry() }
    }

    func revoke(introPublicKey: Data) async {
        var current = loadAll()
        let removedRows = current.filter { $0.introPub == introPublicKey }
        current.removeAll { $0.introPub == introPublicKey }
        if !removedRows.isEmpty {
            writeAll(current)
            let owners = Set(removedRows.compactMap { IdentityID($0.ownerIdentityID) })
            for owner in owners { publish(forOwner: owner) }
        }
    }

    @discardableResult
    func deleteForOwner(_ ownerIdentityID: IdentityID) async -> Int {
        var current = loadAll()
        let before = current.count
        current.removeAll { $0.ownerIdentityID == ownerIdentityID.rawValue.uuidString }
        let removed = before - current.count
        if removed > 0 {
            writeAll(current)
            publish(forOwner: ownerIdentityID)
        }
        return removed
    }

    nonisolated func entriesStream(forOwner ownerIdentityID: IdentityID) -> AsyncStream<[IntroKeyEntry]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(owner: ownerIdentityID, id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(owner: ownerIdentityID, id: id) }
            }
        }
    }

    private func subscribe(
        owner: IdentityID,
        id: UUID,
        continuation: AsyncStream<[IntroKeyEntry]>.Continuation
    ) async {
        continuations[owner, default: [:]][id] = continuation
        continuation.yield(await listForOwner(owner))
    }

    private func unsubscribe(owner: IdentityID, id: UUID) {
        continuations[owner]?.removeValue(forKey: id)
        if continuations[owner]?.isEmpty == true {
            continuations.removeValue(forKey: owner)
        }
    }

    private func publish(forOwner owner: IdentityID) {
        guard let bucket = continuations[owner] else { return }
        let snapshot = loadAll()
            .filter { $0.ownerIdentityID == owner.rawValue.uuidString }
            .sorted { $0.createdAtMillis > $1.createdAtMillis }
            .compactMap { $0.toEntry() }
        for cont in bucket.values { cont.yield(snapshot) }
    }

    /// Test helper — drop the blob entirely. No-op if it's already
    /// gone.
    func wipeAll() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Private

    private func loadAll() -> [StoredIntroKey] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return [] }
        // Corrupted blob → discard rather than crash. Acceptable
        // because this store holds ephemeral per-invite keys; if we
        // lose them, the worst that happens is in-flight invites
        // fail to deliver and the inviter re-shares.
        return (try? JSONDecoder().decode(StoredIntroKeysBlob.self, from: data))?.entries ?? []
    }

    private func writeAll(_ entries: [StoredIntroKey]) {
        guard let data = try? JSONEncoder().encode(StoredIntroKeysBlob(entries: entries)) else {
            return
        }
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
        let updateStatus = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQ = q
            addQ[kSecValueData as String] = data
            addQ[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQ as CFDictionary, nil)
        }
    }
}

/// On-disk envelope. Wraps the list so future fields (sort order,
/// schema version) can be added without re-shaping the JSON.
private struct StoredIntroKeysBlob: Codable {
    var entries: [StoredIntroKey]
}

private struct StoredIntroKey: Codable {
    let introPub: Data
    let introPriv: Data
    let ownerIdentityID: String
    let groupId: Data
    let createdAtMillis: Int64

    enum CodingKeys: String, CodingKey {
        case introPub = "intro_pub"
        case introPriv = "intro_priv"
        case ownerIdentityID = "owner_identity_id"
        case groupId = "group_id"
        case createdAtMillis = "created_at_millis"
    }

    init(from entry: IntroKeyEntry) {
        self.introPub = entry.introPublicKey
        self.introPriv = entry.introPrivateKey
        self.ownerIdentityID = entry.ownerIdentityID.rawValue.uuidString
        self.groupId = entry.groupId
        self.createdAtMillis = Int64(entry.createdAt.timeIntervalSince1970 * 1000)
    }

    func toEntry() -> IntroKeyEntry? {
        guard let owner = IdentityID(ownerIdentityID),
              introPub.count == 32, introPriv.count == 32, groupId.count == 32
        else { return nil }
        return IntroKeyEntry(
            introPublicKey: introPub,
            introPrivateKey: introPriv,
            ownerIdentityID: owner,
            groupId: groupId,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMillis) / 1000)
        )
    }
}
