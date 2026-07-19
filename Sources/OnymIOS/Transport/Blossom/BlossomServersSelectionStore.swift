import Foundation

/// Persistence seam for the Blossom-servers configuration. Mirrors
/// `NostrRelaysSelectionStore` — UserDefaults-backed, no secrets so
/// Keychain would be over-rotation, isolated key prefix
/// (`app.onym.ios.blossom.*`) so other consumers can't collide.
protocol BlossomServersSelectionStore: Sendable {
    func load() -> BlossomServersConfiguration
    func save(_ configuration: BlossomServersConfiguration)
}

/// Production store. UserDefaults-backed; defaults to `.standard` but
/// injectable so tests get an isolated suite.
struct UserDefaultsBlossomServersSelectionStore: BlossomServersSelectionStore, @unchecked Sendable {
    private static let configurationKey = "app.onym.ios.blossom.configuration"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BlossomServersConfiguration {
        guard let data = defaults.data(forKey: Self.configurationKey),
              let config = try? JSONDecoder().decode(
                BlossomServersConfiguration.self,
                from: data
              )
        else {
            return .empty
        }
        return config
    }

    func save(_ configuration: BlossomServersConfiguration) {
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.configurationKey)
        }
    }
}

/// Test-only in-memory store. Lets unit tests assert add/remove
/// behavior without touching the real UserDefaults database.
final class InMemoryBlossomServersSelectionStore: BlossomServersSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BlossomServersConfiguration

    init(initial: BlossomServersConfiguration = .empty) {
        self.stored = initial
    }

    func load() -> BlossomServersConfiguration {
        lock.withLock { stored }
    }

    func save(_ configuration: BlossomServersConfiguration) {
        lock.withLock { stored = configuration }
    }
}
