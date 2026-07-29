import Foundation
import Network

/// Bridges `NWPathMonitor` to an `AsyncStream` of "connectivity was just
/// (re)gained" signals. Each emission is a cue to rebuild long-lived
/// sockets that may have gone stale while the network was down or while
/// the active interface changed (Wi-Fi ↔ cellular hand-off) — the app
/// forwards it to `InboxTransport.reconnect()`.
///
/// The very first `.satisfied` callback at startup is deliberately
/// swallowed: the launch-time connect already establishes the socket, so
/// re-triggering there is pure churn. Every subsequent `.satisfied`
/// update — after an unsatisfied stretch or an interface change — is
/// emitted. Reconnect is idempotent, so erring toward an extra emission
/// is safe.
enum NetworkPathMonitor {
    static func connectivityRegainedStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let gate = FirstCallbackGate()
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                if gate.isFirstCall() { return }
                continuation.yield(())
            }
            continuation.onTermination = { @Sendable _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "app.onym.ios.netpath"))
        }
    }
}

/// Thread-safe one-shot latch: `isFirstCall()` returns `true` exactly
/// once (the first invocation), `false` thereafter. `NWPathMonitor`
/// delivers callbacks on its own queue, so the flip must be synchronized.
private final class FirstCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false

    func isFirstCall() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if seen { return false }
        seen = true
        return true
    }
}
