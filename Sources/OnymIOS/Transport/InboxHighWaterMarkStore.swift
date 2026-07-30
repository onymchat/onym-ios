import Foundation

/// Persisted per-inbox high-water mark: the highest `created_at` (unix
/// seconds) seen on each inbox subscription. Every REQ — initial *and*
/// reconnect replay — is bounded with `since = HWM − slack`, so a
/// reconnect fetches only the gap since the last event we already have,
/// never the full retained history. (Unbounded replays through the
/// serial dispatcher were the flood that starved live chat on
/// invitation-heavy devices — design doc F2/F6.)
///
/// The first-ever run has no mark (nil) ⇒ exactly one unbounded fetch —
/// a cold start genuinely needs the whole backlog (pending invitations).
/// Bounded forever after. Slack + downstream dedup absorb relay clock
/// skew and out-of-order delivery.
protocol InboxHighWaterMarkStoring: Sendable {
    func highWaterMark(inbox: String) -> Int64?
    /// Raise the mark for `inbox` to `createdAt`. Never lowers — a
    /// replayed old event can't shrink the bound.
    func raise(inbox: String, to createdAt: Int64)
}

final class UserDefaultsInboxHighWaterMarkStore: InboxHighWaterMarkStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let key = "app.onym.ios.transport.inboxHighWaterMarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func highWaterMark(inbox: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        let dict = defaults.dictionary(forKey: Self.key) ?? [:]
        return (dict[inbox] as? NSNumber)?.int64Value
    }

    func raise(inbox: String, to createdAt: Int64) {
        lock.lock(); defer { lock.unlock() }
        var dict = defaults.dictionary(forKey: Self.key) ?? [:]
        let current = (dict[inbox] as? NSNumber)?.int64Value ?? Int64.min
        guard createdAt > current else { return }
        dict[inbox] = NSNumber(value: createdAt)
        defaults.set(dict, forKey: Self.key)
    }
}
