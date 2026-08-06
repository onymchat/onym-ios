import Foundation

/// Durable record of intro-request event ids the user already acted on.
///
/// The REQ carries no `since`, so every cold start replays an intro
/// inbox in full. The burn used to make those replays undecodable.
///
/// Scoped by intro pubkey, so `prune(keeping:)` bounds the set by the
/// links that still exist. `maxEntries` backstops one busy link.
public protocol HandledIntroRequestLog: Sendable {
    /// Event ids already acted on, for the reader's fast path.
    func handledIDs() -> Set<String>
    /// Remember `id`, attributed to the link it arrived on.
    func record(id: String, introPublicKey: Data)
    /// Drop tombstones whose link no longer exists.
    func prune(keeping livePublicKeys: Set<Data>)
}

/// UserDefaults-backed: event ids are not secrets, so the Keychain
/// would be over-rotation. Isolated `app.onym.ios.*` key prefix.
public struct UserDefaultsHandledIntroRequestLog: HandledIntroRequestLog, @unchecked Sendable {
    /// Backstop for a busy link. Ids are 64-char hex, so this caps the
    /// blob in the low hundreds of KB.
    public static let maxEntries = 2_000

    private static let storageKey = "app.onym.ios.intro_requests.handled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func handledIDs() -> Set<String> {
        Set(load().map(\.id))
    }

    public func record(id: String, introPublicKey: Data) {
        var rows = load()
        guard !rows.contains(where: { $0.id == id }) else { return }
        rows.append(Row(id: id, introPub: introPublicKey))
        // Oldest-first drop: a replay is likeliest to hit recent ids.
        if rows.count > Self.maxEntries {
            rows.removeFirst(rows.count - Self.maxEntries)
        }
        save(rows)
    }

    public func prune(keeping livePublicKeys: Set<Data>) {
        let rows = load()
        let kept = rows.filter { livePublicKeys.contains($0.introPub) }
        if kept.count != rows.count { save(kept) }
    }

    // MARK: - Private

    private struct Row: Codable {
        let id: String
        let introPub: Data
    }

    private func load() -> [Row] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        // Corrupted blob → start over; one round of replays re-surfaces.
        return (try? JSONDecoder().decode([Row].self, from: data)) ?? []
    }

    private func save(_ rows: [Row]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Test double, and the fallback when no durable log is wired.
public final class InMemoryHandledIntroRequestLog: HandledIntroRequestLog, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Data] = [:]

    public init() {}

    public func handledIDs() -> Set<String> {
        lock.withLock { Set(rows.keys) }
    }

    public func record(id: String, introPublicKey: Data) {
        lock.withLock { rows[id] = introPublicKey }
    }

    public func prune(keeping livePublicKeys: Set<Data>) {
        lock.withLock { rows = rows.filter { livePublicKeys.contains($0.value) } }
    }
}
