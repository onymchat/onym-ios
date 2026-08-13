import Foundation

/// Persistence seam for the discovery configuration and the retained
/// snapshot bytes. UserDefaults-backed — nothing here is secret (the
/// configuration is public endpoints plus public keys, and snapshots
/// are published documents), same reasoning as
/// `UserDefaultsRelayerSelectionStore`.
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
    /// Delete every retained snapshot of a removed source. Its
    /// `catalogIds` come from the source's `lastAccepted` keys.
    func removeRetainedSnapshots(providerId: String, catalogIds: [String])
}

/// Production `DiscoveryStore`. Keys are scoped under
/// `app.onym.ios.discovery.*`; the suite is injectable so each test
/// gets an isolated suite.
///
/// `@unchecked Sendable` for the same reason as the sibling stores:
/// `UserDefaults` is documented thread-safe but not formally `Sendable`.
public struct UserDefaultsDiscoveryStore: DiscoveryStore, @unchecked Sendable {
    private static let prefix = "app.onym.ios.discovery."
    private static let configurationKey = prefix + "configuration"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        defaults.data(forKey: Self.snapshotKey(providerId: providerId, catalogId: catalogId))
    }

    public func saveRetainedSnapshot(_ raw: Data, providerId: String, catalogId: String) {
        defaults.set(raw, forKey: Self.snapshotKey(providerId: providerId, catalogId: catalogId))
    }

    public func removeRetainedSnapshots(providerId: String, catalogIds: [String]) {
        for catalogId in catalogIds {
            defaults.removeObject(forKey: Self.snapshotKey(providerId: providerId, catalogId: catalogId))
        }
    }

    private static func snapshotKey(providerId: String, catalogId: String) -> String {
        // providerId and catalogId are validated to [a-z0-9-:] shapes,
        // so "|" can never appear in either — the key is unambiguous.
        prefix + "snapshot." + providerId + "|" + catalogId
    }
}
