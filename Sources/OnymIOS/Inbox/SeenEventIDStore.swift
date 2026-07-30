import Foundation

/// Durable, bounded record of Nostr event ids that have already been
/// fully dispatched. The inbox fan-out consults it *before* decrypting,
/// so re-delivered events — the HWM slack window, the same event from
/// multiple relays, a reconnect's replay — cost a set lookup instead of
/// an X25519/AES-GCM decrypt and a possible chain read.
///
/// Ids are marked seen only *after* a dispatch completes: a crash midway
/// re-delivers (all dispatch paths are idempotent) rather than losing the
/// event. Eviction is insertion-ordered FIFO with a fixed capacity —
/// events older than the window are already excluded by the HWM `since`
/// bound, so the set only needs to cover the recent overlap.
///
/// Persistence is debounced (bursty replays write once, not per event);
/// losing the tail of unsaved marks on a kill is harmless — the events
/// re-dispatch idempotently next launch.
actor SeenEventIDStore {
    private let defaults: UserDefaults
    private let capacity: Int
    private var order: [String]
    private var members: Set<String>
    private var persistScheduled = false
    private static let key = "app.onym.ios.inbox.seenEventIDs"
    private static let persistDebounce: Duration = .seconds(1)

    init(defaults: UserDefaults = .standard, capacity: Int = 4096) {
        self.defaults = defaults
        self.capacity = capacity
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        self.order = Array(stored.suffix(capacity))
        self.members = Set(order)
    }

    func contains(_ id: String) -> Bool {
        members.contains(id)
    }

    func markSeen(_ id: String) {
        guard !members.contains(id) else { return }
        members.insert(id)
        order.append(id)
        if order.count > capacity {
            let evicted = order.removeFirst()
            members.remove(evicted)
        }
        schedulePersist()
    }

    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task {
            try? await Task.sleep(for: Self.persistDebounce)
            self.persistNow()
        }
    }

    private func persistNow() {
        persistScheduled = false
        defaults.set(order, forKey: Self.key)
    }
}
