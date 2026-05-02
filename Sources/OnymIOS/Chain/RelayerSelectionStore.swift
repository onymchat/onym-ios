import Foundation

/// Persistence seam for the user's selected relayer + the cached
/// known-relayers list. UserDefaults-backed — the URL isn't secret
/// (it's a public service endpoint) and Keychain access for a non-
/// secret would be an over-rotation.
///
/// Two seams in one protocol because they share the same backing
/// store and lifecycle (both are app-level config, not domain data).
protocol RelayerSelectionStore: Sendable {
    func loadSelection() -> RelayerSelection?
    func saveSelection(_ selection: RelayerSelection?)

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
    private static let selectionKey = "chat.onym.ios.relayer.selection"
    private static let cachedListKey = "chat.onym.ios.relayer.cachedKnownList"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSelection() -> RelayerSelection? {
        guard let data = defaults.data(forKey: Self.selectionKey) else { return nil }
        return try? JSONDecoder().decode(RelayerSelection.self, from: data)
    }

    func saveSelection(_ selection: RelayerSelection?) {
        if let selection, let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
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
}
