import Foundation

/// Persistence seam for the user's relayer configuration + the cached
/// known-relayers list. UserDefaults-backed — neither is secret (the
/// URL is a public service endpoint and the strategy choice isn't
/// sensitive) and Keychain access for non-secret config would be an
/// over-rotation.
///
/// Two seams in one protocol because they share the same backing
/// store and lifecycle (both are app-level config, not domain data).
protocol RelayerSelectionStore: Sendable {
    /// Returns the persisted configuration, or `.empty` if none has
    /// ever been saved. Implementations also handle one-time migration
    /// from the PR #18 single-selection format here.
    func loadConfiguration() -> RelayerConfiguration
    func saveConfiguration(_ configuration: RelayerConfiguration)

    func loadCachedKnownList() -> [RelayerEndpoint]
    func saveCachedKnownList(_ list: [RelayerEndpoint])
}

/// Production `RelayerSelectionStore`. Keys are scoped under
/// `chat.onym.ios.relayer.*` so other UserDefaults consumers can't
/// collide. Suite name is injectable so each test gets its own
/// isolated suite (mirrors the per-test Keychain service pattern in
/// `IdentityRepositoryTests`).
///
/// `@unchecked Sendable` because `UserDefaults` is documented as
/// thread-safe (its set / remove / data(forKey:) APIs serialise
/// internally) but isn't formally `Sendable` in the standard library.
struct UserDefaultsRelayerSelectionStore: RelayerSelectionStore, @unchecked Sendable {
    private static let configurationKey = "chat.onym.ios.relayer.configuration"
    private static let cachedListKey = "chat.onym.ios.relayer.cachedKnownList"
    /// PR #18 key — read once for migration, then deleted.
    private static let legacySelectionKey = "chat.onym.ios.relayer.selection"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadConfiguration() -> RelayerConfiguration {
        if let data = defaults.data(forKey: Self.configurationKey),
           let config = try? JSONDecoder().decode(RelayerConfiguration.self, from: data) {
            return config
        }
        // Migration from PR #18's single-selection format. Runs at most
        // once per install — after we successfully save the migrated
        // config the legacy key is removed.
        if let migrated = migrateLegacySelection() {
            saveConfiguration(migrated)
            defaults.removeObject(forKey: Self.legacySelectionKey)
            return migrated
        }
        return .empty
    }

    func saveConfiguration(_ configuration: RelayerConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            defaults.removeObject(forKey: Self.configurationKey)
            return
        }
        defaults.set(data, forKey: Self.configurationKey)
    }

    func loadCachedKnownList() -> [RelayerEndpoint] {
        guard let data = defaults.data(forKey: Self.cachedListKey),
              let list = try? JSONDecoder().decode([RelayerEndpoint].self, from: data)
        else { return [] }
        return list
    }

    func saveCachedKnownList(_ list: [RelayerEndpoint]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Self.cachedListKey)
    }

    // MARK: - PR #18 migration

    /// Decode the old `RelayerSelection` enum (`.known` / `.custom`)
    /// from PR #18 and project to a one-endpoint `RelayerConfiguration`
    /// with that endpoint as primary, strategy `.primary`.
    private func migrateLegacySelection() -> RelayerConfiguration? {
        guard let data = defaults.data(forKey: Self.legacySelectionKey) else {
            return nil
        }
        guard let endpoint = decodeLegacyEndpoint(from: data) else {
            // Legacy blob present but unreadable — drop it without
            // synthesising a config so the user lands on the empty
            // state rather than an arbitrary endpoint.
            defaults.removeObject(forKey: Self.legacySelectionKey)
            return nil
        }
        return RelayerConfiguration(
            endpoints: [endpoint],
            primaryURL: endpoint.url,
            strategy: .primary
        )
    }

    /// Decode the legacy enum without keeping the old type around in
    /// the production codebase. Mirrors the wire format the PR #18
    /// `RelayerSelection` codable produced (Swift's automatic enum
    /// codable: a single-key dictionary keyed by case name with the
    /// associated value as the value).
    private func decodeLegacyEndpoint(from data: Data) -> RelayerEndpoint? {
        struct LegacySelection: Decodable {
            let known: RelayerEndpoint?
            let custom: LegacyCustom?

            struct LegacyCustom: Decodable {
                let _0: URL
            }
        }
        guard let legacy = try? JSONDecoder().decode(LegacySelection.self, from: data) else {
            return nil
        }
        if let known = legacy.known { return known }
        if let url = legacy.custom?._0 { return .custom(url: url) }
        return nil
    }
}
