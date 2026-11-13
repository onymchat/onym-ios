import Foundation
import OnymIdentity

/// People this device's identities have blocked.
///
/// Blocking is per local identity (the owner) and keyed by the sender's
/// BLS public key — the roster key a chat message names its author by.
/// A blocked sender's messages are removed from the owner's threads the
/// moment they're blocked (`MessageRepository.removeIncoming`), and new
/// ones are dropped on arrival (`IncomingMessageDispatcher`), so nothing
/// from them reaches the feed again until they're unblocked.
///
/// Stored in UserDefaults: a list of public keys and the alias shown
/// next to them, nothing from any message. `@unchecked Sendable` for the
/// same reason as the app's other UserDefaults stores — UserDefaults is
/// documented thread-safe but not formally `Sendable`.
public final class BlockedSenders: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let owner: IdentityID
        /// Lowercase hex.
        public let senderBlsPubkeyHex: String
        public let alias: String
        public let blockedAt: Date

        public var id: String { "\(owner.rawValue.uuidString):\(senderBlsPubkeyHex)" }
    }

    static let key = "app.onym.ios.blockedSenders.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func entries(owner: IdentityID) -> [Entry] {
        all().filter { $0.owner == owner }
    }

    public func isBlocked(senderBlsPubkeyHex: String, owner: IdentityID) -> Bool {
        let sender = senderBlsPubkeyHex.lowercased()
        return all().contains { $0.owner == owner && $0.senderBlsPubkeyHex == sender }
    }

    public func block(senderBlsPubkeyHex: String, alias: String, owner: IdentityID, at date: Date = Date()) {
        let sender = senderBlsPubkeyHex.lowercased()
        mutate { entries in
            guard !entries.contains(where: { $0.owner == owner && $0.senderBlsPubkeyHex == sender }) else { return }
            entries.append(Entry(owner: owner, senderBlsPubkeyHex: sender, alias: alias, blockedAt: date))
        }
    }

    public func unblock(senderBlsPubkeyHex: String, owner: IdentityID) {
        let sender = senderBlsPubkeyHex.lowercased()
        mutate { $0.removeAll { $0.owner == owner && $0.senderBlsPubkeyHex == sender } }
    }

    /// Forget every block an identity made — for when the identity itself
    /// is removed.
    public func removeOwner(_ owner: IdentityID) {
        mutate { $0.removeAll { $0.owner == owner } }
    }

    private func all() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    private func mutate(_ change: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = read()
        change(&entries)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func read() -> [Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
