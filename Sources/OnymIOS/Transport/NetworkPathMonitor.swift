import Foundation
import Network

/// Bridges `NWPathMonitor` to an `AsyncStream` of "connectivity was just
/// regained" signals. Each emission is a cue to refresh long-lived
/// sockets — the app forwards it to `InboxTransport.reconnect()`.
///
/// Emission policy lives in `ConnectivityRegainDetector` (below):
///
///  - **Edge-triggered.** `NWPathMonitor` invokes its handler on *any*
///    path change, including route/interface/proxy churn while the path
///    stays satisfied (frequent on real devices). Emitting on every
///    satisfied callback caused a reconnect storm (design doc F2). We
///    emit only on a genuine unsatisfied→satisfied transition.
///  - **Baseline suppressed.** The first callback establishes the
///    starting state and never emits — the launch-time connect already
///    covers a satisfied start, while an *unsatisfied* start still arms
///    the detector so the first real regain fires (launch-offline case).
///  - **Coalesced.** A flapping link emits at most once per cooldown
///    window, so the transport isn't rebuilt at the flap rate.
enum NetworkPathMonitor {
    static func connectivityRegainedStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let detector = ConnectivityRegainDetector()
            monitor.pathUpdateHandler = { path in
                if detector.shouldEmit(satisfied: path.status == .satisfied) {
                    continuation.yield(())
                }
            }
            continuation.onTermination = { @Sendable _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "app.onym.ios.netpath"))
        }
    }
}

/// Decides when a sequence of `NWPathMonitor` status callbacks should
/// produce a "connectivity regained" signal. Pure logic with an
/// injectable clock — no `Network` dependency — so the edge + cooldown
/// behavior is unit-testable. Callbacks arrive on `NWPathMonitor`'s own
/// queue, so state is lock-guarded.
final class ConnectivityRegainDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSatisfied: Bool?
    private var lastEmitAt: Date?
    private let cooldown: TimeInterval
    private let now: () -> Date

    init(cooldown: TimeInterval = 3, now: @escaping () -> Date = Date.init) {
        self.cooldown = cooldown
        self.now = now
    }

    func shouldEmit(satisfied: Bool) -> Bool {
        lock.lock()
        defer { lastSatisfied = satisfied; lock.unlock() }
        // First callback is the baseline — arm, never emit.
        guard let previous = lastSatisfied else { return false }
        // Only the unsatisfied→satisfied edge is a regain.
        guard satisfied, !previous else { return false }
        // Debounce a flapping link.
        let timestamp = now()
        if let last = lastEmitAt, timestamp.timeIntervalSince(last) < cooldown {
            return false
        }
        lastEmitAt = timestamp
        return true
    }
}
