import Foundation

/// Persistence seam for the Nostr-relays configuration. Mirrors
/// `RelayerSelectionStore`'s shape — UserDefaults-backed, no
/// secrets so Keychain would be over-rotation, isolated key prefix
/// (`chat.onym.ios.nostr.*`) so other consumers can't collide.
protocol NostrRelaysSelectionStore: Sendable {
    func load() -> NostrRelaysConfiguration
    func save(_ configuration: NostrRelaysConfiguration)
}

/// Production store. UserDefaults-backed; defaults to `.standard` but
/// injectable so tests get an isolated suite.
struct UserDefaultsNostrRelaysSelectionStore: NostrRelaysSelectionStore, @unchecked Sendable {
    private static let configurationKey = "chat.onym.ios.nostr.configuration"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> NostrRelaysConfiguration {
        guard let data = defaults.data(forKey: Self.configurationKey),
              let config = try? JSONDecoder().decode(
                NostrRelaysConfiguration.self,
                from: data
              )
        else {
            return .empty
        }
        return config
    }

    func save(_ configuration: NostrRelaysConfiguration) {
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: Self.configurationKey)
        }
    }
}

/// Test-only in-memory store. Lets unit tests assert add/remove
/// behavior without touching the real UserDefaults database.
final class InMemoryNostrRelaysSelectionStore: NostrRelaysSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NostrRelaysConfiguration

    init(initial: NostrRelaysConfiguration = .empty) {
        self.stored = initial
    }

    func load() -> NostrRelaysConfiguration {
        lock.withLock { stored }
    }

    func save(_ configuration: NostrRelaysConfiguration) {
        lock.withLock { stored = configuration }
    }
}
