/// The one long-lived subscription a treasury flow holds, and the
/// lifecycle both flows kept a copy of.
///
/// `IdentityScopedFlowCache` removed the duplicated *cache*; this
/// removes the duplicated thing that cache manages. Of the defects that
/// landed in one of `TreasuryFlow` / `TreasuryProposalsFlow` and were
/// fixed only there, three were in these few lines — `start()`'s
/// re-entry guard, the detachment that lets the stream survive the row
/// being recycled, and the cancellation `stop()` performs. A shared
/// shape does not stay in sync; a shared implementation cannot drift.
///
/// What stays on each flow is what genuinely differs: *what* it drains
/// and what it reads before draining.
@MainActor
final class FlowSubscription {
    /// The live task, if one is draining.
    ///
    /// Not a `started` flag. Both flows are memoised for the app's
    /// lifetime, and both consumed the stream inline on a view's
    /// `.task` at some point: popping the treasury screen, or the
    /// thread row being recycled, cancelled that task, the iteration
    /// ended, and a one-shot flag stayed true — so every later visit
    /// rendered state frozen at the moment of the last exit.
    private var task: Task<Void, Never>?

    /// Opens the subscription if one is not already draining, and
    /// awaits it — so the caller's `.task` stays alive for as long as
    /// the stream does.
    ///
    /// Idempotent: safe to call from every `.task` that shows the flow,
    /// however many times a view is rebuilt.
    func start(_ drain: @escaping @Sendable @MainActor () async -> Void) async {
        guard task == nil else { return }
        // Unstructured on purpose. An unstructured `Task` does not
        // inherit the caller's cancellation, so the stream survives the
        // `.task` that opened it being torn down — the treasury screen
        // popped, the thread's row recycled. One subscription per flow,
        // opened once, and the guard above keeps a second view from
        // opening another.
        //
        // Deliberately no `task = nil` on the way out: it would fire as
        // a cancelled iteration unwinds and could null out a task a
        // later `start()` has already installed.
        let task = Task { await drain() }
        self.task = task
        await task.value
    }

    /// End the subscription.
    ///
    /// Needed because the task deliberately outlives the view: it holds
    /// the flow strongly while draining a stream the repository never
    /// finishes, so a flow nobody references any more stays alive and
    /// subscribed for the rest of the run — woken by every snapshot of
    /// a group belonging to an identity that is no longer selected.
    /// `IdentityScopedFlowCache` cancels here before dropping an entry;
    /// dropping the dictionary's reference alone does not stop it.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
