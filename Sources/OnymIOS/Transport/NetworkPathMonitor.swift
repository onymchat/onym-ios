import Foundation
import Network

/// Bridges `NWPathMonitor` to an `AsyncStream` of "connectivity was just
/// regained" signals. Each emission is a cue to rebuild long-lived
/// sockets that went dead while the network was down — the app forwards
/// it to `InboxTransport.reconnect()`.
///
/// Emits **only on a genuine unsatisfied→satisfied transition.**
/// `NWPathMonitor` invokes its handler on *any* path change, including
/// route/interface churn while the path stays satisfied (frequent on the
/// simulator). Emitting on every satisfied callback turned this into a
/// reconnect storm — each reconnect makes the relay replay every retained
/// event, so the whole inbox pipeline thrashes. Tracking the previous
/// status and firing only on the offline→online edge fixes that. The
/// baseline (first) callback never emits: the launch-time connect already
/// covers a satisfied start.
enum NetworkPathMonitor {
    static func connectivityRegainedStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let tracker = SatisfiedTransitionTracker()
            monitor.pathUpdateHandler = { path in
                if tracker.shouldEmit(satisfied: path.status == .satisfied) {
                    continuation.yield(())
                }
            }
            continuation.onTermination = { @Sendable _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "app.onym.ios.netpath"))
        }
    }
}

/// Thread-safe edge detector for connectivity. `shouldEmit` returns `true`
/// only when the path flips from not-satisfied to satisfied; the first
/// call establishes the baseline and never emits. `NWPathMonitor`
/// delivers callbacks on its own queue, so the state must be synchronized.
private final class SatisfiedTransitionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSatisfied: Bool?

    func shouldEmit(satisfied: Bool) -> Bool {
        lock.lock()
        defer { lastSatisfied = satisfied; lock.unlock() }
        guard let previous = lastSatisfied else { return false }
        return satisfied && !previous
    }
}
