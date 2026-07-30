import Foundation
import Observation

/// Owns the inbox transport's lifecycle end to end: the initial connect,
/// the unconditional rebuild on app-lifecycle triggers (return to
/// foreground, regained connectivity), and the connection-state signal.
///
/// Layering contract: this repository is the ONLY component that drives
/// the transport, and `connectionSnapshots` is the ONLY thing the
/// presentation layer consumes from it. No view code observes lifecycle
/// notifications or calls `reconnect()` — the trigger streams are
/// injected (the app shell passes `UIApplication`-notification and
/// `NWPathMonitor` streams; tests pass hand-driven ones), so the
/// repository itself is UIKit-free and the transport's lifetime is
/// independent of any view's.
///
/// Note there is no "reconnect failed" event by design: the transport
/// retries internally with escalating backoff and never gives up, so the
/// honest presentation signal is the continuous connected/disconnected
/// state — a failure shows as `false` persisting, and recovery flips it
/// back without any extra machinery.
actor TransportLifecycleRepository {
    private let transport: any InboxTransport
    private let foregroundSignals: AsyncStream<Void>
    private let connectivitySignals: AsyncStream<Void>
    private var triggerTasks: [Task<Void, Never>] = []
    private var mirrorTask: Task<Void, Never>?
    private var started = false

    /// Latest known state, replayed to new subscribers. Optimistic
    /// `true` before the first transport report so the UI doesn't flash
    /// an offline indicator during a normal launch.
    private var isConnected = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    init(
        transport: any InboxTransport,
        foregroundSignals: AsyncStream<Void>,
        connectivitySignals: AsyncStream<Void>
    ) {
        self.transport = transport
        self.foregroundSignals = foregroundSignals
        self.connectivitySignals = connectivitySignals
    }

    /// Connect to `endpoints` and begin owning the lifecycle. Returns
    /// once the initial connect has been issued (callers that must
    /// subscribe only after connect — the fan-out — can await this).
    /// Idempotent.
    func start(endpoints: [TransportEndpoint]) async {
        guard !started else { return }
        started = true

        await transport.connect(to: endpoints)

        // Mirror the transport's confirmed-live aggregate into the
        // presentation-facing snapshots.
        let stateStream = transport.connectionStateStream()
        mirrorTask = Task { [weak self] in
            for await connected in stateStream {
                await self?.updateConnected(connected)
            }
        }

        // Both triggers rebuild unconditionally: a fresh REQ is the only
        // mechanism that backfills events missed while suspended, and
        // the rebuild is cheap (since-bounded replay + pre-decrypt
        // dedup). The streams are already edge-triggered/debounced at
        // their sources.
        let transport = self.transport
        triggerTasks.append(Task { [foregroundSignals] in
            for await _ in foregroundSignals {
                // A yield buffered before stop()'s cancel can still
                // resume the loop — never forward it.
                guard !Task.isCancelled else { break }
                await transport.reconnect()
            }
        })
        triggerTasks.append(Task { [connectivitySignals] in
            for await _ in connectivitySignals {
                guard !Task.isCancelled else { break }
                await transport.reconnect()
            }
        })
    }

    func stop() async {
        for task in triggerTasks { task.cancel() }
        triggerTasks.removeAll()
        mirrorTask?.cancel()
        mirrorTask = nil
        started = false
    }

    /// Hot stream of the connection state for the presentation layer.
    /// Replays the current value on subscribe.
    nonisolated var connectionSnapshots: AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func updateConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        for continuation in continuations.values {
            continuation.yield(connected)
        }
    }

    private func subscribe(id: UUID, continuation: AsyncStream<Bool>.Continuation) {
        continuations[id] = continuation
        continuation.yield(isConnected)
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

/// `@Observable` mirror of the repository's connection state for SwiftUI
/// — the presentation layer's entire view of the transport. Mirrors the
/// flow shape used across the app (`PendingInvitesFlow` etc.).
@MainActor
@Observable
final class ConnectionStatusFlow {
    /// `false` while no relay is confirmed live — drives the offline
    /// indicator on the chats screen.
    private(set) var isConnected = true

    private let repository: TransportLifecycleRepository
    private var streamTask: Task<Void, Never>?

    init(repository: TransportLifecycleRepository) {
        self.repository = repository
    }

    /// Idempotent.
    func start() {
        guard streamTask == nil else { return }
        let snapshots = repository.connectionSnapshots
        streamTask = Task { @MainActor [weak self] in
            for await connected in snapshots {
                self?.isConnected = connected
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }
}
