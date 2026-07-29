import Foundation

/// FIFO serial execution lane: jobs run strictly in enqueue order, one
/// at a time, without blocking the enqueuer. Implemented as a chain of
/// Tasks — each new job awaits the previous tail before running.
///
/// This is the dispatcher's *slow lane*: invitation / group-state
/// payloads (which may hit the relayer for a chain read) are enqueued
/// here so a backlog of them can never starve live chat delivery — the
/// fan-out's `for await → dispatch` loop returns immediately for slow
/// payloads instead of stalling behind a network round-trip per event
/// (design doc F6: an invitation-spammed device queued live messages
/// behind minutes of chain reads).
actor SerialDispatchLane {
    private var tail: Task<Void, Never>?
    private var enqueuedCount = 0

    /// Append a job. Returns immediately; the job runs after every job
    /// enqueued before it has finished.
    func enqueue(_ job: @escaping @Sendable () async -> Void) {
        enqueuedCount += 1
        let previous = tail
        tail = Task {
            await previous?.value
            await job()
        }
    }

    /// Suspend until everything enqueued so far — including jobs that
    /// running jobs enqueue (e.g. the chat group-not-found retry) — has
    /// finished. Test seam; production code never needs a barrier.
    func drain() async {
        while true {
            let snapshot = enqueuedCount
            guard let current = tail else { return }
            await current.value
            if enqueuedCount == snapshot { return }
        }
    }
}
