import Foundation

/// Persistence seam for the discovery configuration and the retained
/// snapshot bytes. Nothing here is secret (the configuration is public
/// endpoints plus public keys, and snapshots are published documents),
/// same reasoning as `UserDefaultsRelayerSelectionStore` — but
/// snapshots are up to 1 MiB *per catalog*, so blobs live as files
/// rather than in UserDefaults (which is a single plist loaded whole
/// into memory).
///
/// Retained snapshots are the **exact accepted bytes** per
/// (providerId, catalogId): they feed the next refresh's
/// `previousDigest` chain check and keep entries available offline.
public protocol DiscoveryStore: Sendable {
    /// Returns the persisted configuration, or `.empty` if none has
    /// ever been saved.
    func loadConfiguration() -> DiscoverySourcesConfiguration
    func saveConfiguration(_ configuration: DiscoverySourcesConfiguration)

    func loadRetainedSnapshot(providerId: String, catalogId: String) -> Data?
    func saveRetainedSnapshot(_ raw: Data, providerId: String, catalogId: String)
    /// Delete **every** retained snapshot of a removed source, by
    /// provider prefix — not by an enumerated catalog list, so blobs
    /// orphaned by a catalog the manifest later dropped (or by a
    /// partial refresh) are removed too and can never poison a re-add
    /// of the same provider.
    func removeRetainedSnapshots(providerId: String)
}

/// Production `DiscoveryStore`: small configuration in UserDefaults
/// (keys scoped under `app.onym.ios.discovery.*`, suite injectable so
/// each test gets an isolated suite), snapshot blobs as files under
/// `Application Support/OnymDiscovery/Snapshots/<providerId>/<catalogId>.json`
/// (directory injectable for tests). `providerId` and `catalogId` are
/// validated to `[a-z0-9-:]` / `[a-z0-9-]` shapes, so both are
/// POSIX-filename-safe and the per-provider directory is unambiguous.
///
/// Blobs written by earlier builds into UserDefaults
/// (`app.onym.ios.discovery.snapshot.<providerId>|<catalogId>`) are
/// migrated to files on init and removed from the defaults.
///
/// `@unchecked Sendable` for the same reason as the sibling stores:
/// `UserDefaults` and `FileManager` are documented thread-safe but
/// not formally `Sendable`.
public struct DefaultDiscoveryStore: DiscoveryStore, @unchecked Sendable {
    private static let prefix = "app.onym.ios.discovery."
    private static let configurationKey = prefix + "configuration"
    /// Pre-file-store builds kept snapshot bytes directly in the
    /// defaults under this prefix. Retained only for migration.
    static let legacySnapshotKeyPrefix = prefix + "snapshot."

    private let defaults: UserDefaults
    private let snapshotsDirectory: URL

    public init(defaults: UserDefaults = .standard, snapshotsDirectory: URL? = nil) {
        self.defaults = defaults
        self.snapshotsDirectory = snapshotsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnymDiscovery", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
        migrateLegacySnapshots()
    }

    public func loadConfiguration() -> DiscoverySourcesConfiguration {
        guard let data = defaults.data(forKey: Self.configurationKey),
              let config = try? JSONDecoder().decode(DiscoverySourcesConfiguration.self, from: data)
        else { return .empty }
        return config
    }

    public func saveConfiguration(_ configuration: DiscoverySourcesConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            defaults.removeObject(forKey: Self.configurationKey)
            return
        }
        defaults.set(data, forKey: Self.configurationKey)
    }

    public func loadRetainedSnapshot(providerId: String, catalogId: String) -> Data? {
        try? Data(contentsOf: snapshotFileURL(providerId: providerId, catalogId: catalogId))
    }

    public func saveRetainedSnapshot(_ raw: Data, providerId: String, catalogId: String) {
        let url = snapshotFileURL(providerId: providerId, catalogId: catalogId)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? raw.write(to: url, options: .atomic)
    }

    public func removeRetainedSnapshots(providerId: String) {
        // Prefix removal: the whole per-provider directory goes, so
        // orphaned blobs never outlive the source.
        try? FileManager.default.removeItem(at: providerDirectory(providerId: providerId))
        // Belt and braces: un-migrated legacy defaults entries for this
        // provider (e.g. the migration raced a fresh save) go too.
        let legacyPrefix = Self.legacySnapshotKeyPrefix + providerId + "|"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Private

    private func providerDirectory(providerId: String) -> URL {
        snapshotsDirectory.appendingPathComponent(providerId, isDirectory: true)
    }

    private func snapshotFileURL(providerId: String, catalogId: String) -> URL {
        providerDirectory(providerId: providerId)
            .appendingPathComponent(catalogId)
            .appendingPathExtension("json")
    }

    /// One-shot migration of pre-file-store snapshot blobs out of
    /// UserDefaults. A blob whose file already exists is dropped, not
    /// copied — the file is the newer write.
    private func migrateLegacySnapshots() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.legacySnapshotKeyPrefix) {
            defer { defaults.removeObject(forKey: key) }
            // Legacy key shape: <prefix><providerId>|<catalogId>;
            // providerId/catalogId charsets exclude "|", so the first
            // separator is unambiguous.
            let rest = key.dropFirst(Self.legacySnapshotKeyPrefix.count)
            guard let separator = rest.firstIndex(of: "|") else { continue }
            let providerId = String(rest[..<separator])
            let catalogId = String(rest[rest.index(after: separator)...])
            guard !providerId.isEmpty, !catalogId.isEmpty,
                  let raw = defaults.data(forKey: key)
            else { continue }
            let url = snapshotFileURL(providerId: providerId, catalogId: catalogId)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            saveRetainedSnapshot(raw, providerId: providerId, catalogId: catalogId)
        }
    }
}

/// Historical name from when snapshot blobs also lived in
/// UserDefaults; call sites keep compiling. New code should say
/// `DefaultDiscoveryStore`.
public typealias UserDefaultsDiscoveryStore = DefaultDiscoveryStore
