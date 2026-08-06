import Foundation
import Observation

/// Drives the post-deeplink-tap "Join this chat" surface. State
/// machine:
///
///  ```
///           ┌──────► ready ──── send ──► sending
///  init ────┤                                │
///           │                                ▼
///           │                       ┌─►  awaitingApproval ─┐
///           │                       │  (sender.send → sent)│
///           │                       │                      │
///           │  failed ◄──── send ───┘                      │
///           │  (sender.send → ...)                         │
///           │                                              ▼
///           └──────► approved ◄────────────────────────── group lands in repo
///                  (already a member, OR
///                   sealed invitation arrives via the
///                   inbox-fanout pump after inviter Approves)
///  ```
///
/// - **ready**: capability decoded, joiner hasn't tapped Send.
/// - **sending**: `JoinRequestSender.send` in flight. Debounced —
///   a second `send` while one is in flight is a no-op.
/// - **awaitingApproval**: request shipped, waiting for the inviter
///   to tap Approve and ship the sealed invitation back. In-memory
///   only; backgrounding is fine while the process lives, but a
///   force-quit drops the wait — the inviter's Approve still works
///   since the invitation lands in the joiner's persisted inbox via
///   `IncomingInvitationsRepository` and surfaces as a chat next
///   time the joiner opens the app.
/// - **approved**: the matching `ChatGroup` has appeared in the
///   repository — either because the joiner is already a member
///   (re-tap of an old link) or because the inviter approved + the
///   invitation pipeline materialized the group.
/// - **failed**: surface a reason + Retry. Retry resets to `ready`
///   and re-fires `send`.
///
/// The repository watcher runs for the flow's lifetime — it can
/// flip to `approved` from any non-terminal state. This handles
/// the already-a-member case at construction and the
/// sealed-invitation-arrives case after Send.
///
/// Mirrors onym-android's `JoinViewModel.kt`.
@MainActor
@Observable
final class JoinFlow {
    enum State: Equatable, Sendable {
        case ready(IntroCapability)
        case sending
        case awaitingApproval
        /// The request went out and nothing came back for
        /// `unansweredAfter`. Not a failure — the host may simply be
        /// offline — but invite links can now be revoked, and a
        /// revoked link is indistinguishable from a slow host from
        /// here. Saying so beats an indefinite spinner.
        case unanswered
        case approved(ChatGroup)
        case failed(reason: String)
    }

    let capability: IntroCapability
    /// Pre-filled into the display-label TextField. User can edit
    /// before Send. The factory in `OnymIOSApp` derives it from the
    /// active identity's display name at construction time.
    let suggestedDisplayLabel: String

    private(set) var state: State

    private let submitRequest: @Sendable (IntroCapability, String) async -> JoinRequestSender.Outcome
    private let groupRepository: GroupRepository

    private var sendTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var unansweredTask: Task<Void, Never>?
    /// How long this flow waits before flipping to `.unanswered`, or
    /// nil to never flip. Injected so tests can drive the timeout in
    /// milliseconds instead of sitting out the real 90 seconds.
    private let unansweredAfter: Duration?

    init(
        capability: IntroCapability,
        suggestedDisplayLabel: String,
        submitRequest: @escaping @Sendable (IntroCapability, String) async -> JoinRequestSender.Outcome,
        groupRepository: GroupRepository,
        unansweredAfter: Duration? = JoinFlow.unansweredAfter
    ) {
        self.capability = capability
        self.suggestedDisplayLabel = suggestedDisplayLabel
        self.submitRequest = submitRequest
        self.groupRepository = groupRepository
        self.unansweredAfter = unansweredAfter
        self.state = .ready(capability)
        startWatcher()
    }

    // No deinit Task cleanup — both `sendTask` and `watcherTask`
    // capture `[weak self]` so they exit gracefully on deallocation
    // without needing main-actor-isolated cancellation in `deinit`
    // (which Swift's strict concurrency checking would flag).

    /// How long to wait on `awaitingApproval` before telling the user
    /// nothing has come back.
    ///
    /// Deliberately generous: approval is a human action plus a
    /// multi-second proof and a chain round-trip on the host's device,
    /// so anything short would cry wolf on a host who is simply
    /// thinking. The watcher stays live afterwards — a late approval
    /// still flips straight to `.approved`.
    static let unansweredAfter: Duration = .seconds(90)

    /// Ship the join request. No-op if a previous `send` is in flight
    /// (debounce — protects against double-tap on the primary
    /// button) or if state isn't `.ready` / `.failed`.
    func send(displayLabel: String) {
        if let sendTask, !sendTask.isCancelled, sendTask.isCancelled == false {
            // sendTask exists; conservatively no-op.
            // (Task isCancelled is a weak signal but Swift has no
            // public "isFinished" — after one tap the subsequent
            // tap will be guarded by the state check below anyway.)
        }
        switch state {
        case .ready, .failed: break
        default: return
        }
        sendTask = Task { [weak self, submitRequest, capability] in
            guard let self else { return }
            self.state = .sending
            let outcome = await submitRequest(capability, displayLabel)
            // The watcher may have flipped us to `.approved` while
            // we were awaiting — defer to it if so.
            if case .approved = self.state { return }
            switch outcome {
            case .sent:
                self.state = .awaitingApproval
                self.startUnansweredTimer()
            case .noIdentityLoaded:
                self.state = .failed(reason: "Sign in first.")
            case .transportFailed(let reason):
                self.state = .failed(reason: "Couldn't send: \(reason)")
            }
        }
    }

    /// Flip to `.unanswered` if nothing has landed by the deadline.
    /// Cancelled implicitly by the flow going away; a late approval
    /// overwrites the state via the watcher either way.
    private func startUnansweredTimer() {
        guard let unansweredAfter else { return }
        unansweredTask?.cancel()
        unansweredTask = Task { [weak self] in
            try? await Task.sleep(for: unansweredAfter)
            guard let self, !Task.isCancelled else { return }
            guard case .awaitingApproval = self.state else { return }
            self.state = .unanswered
        }
    }

    private func startWatcher() {
        let stream = groupRepository.snapshots
        let target = capability.groupId
        watcherTask = Task { [weak self] in
            for await groups in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                guard let match = groups.first(where: { $0.groupIDData == target }) else {
                    continue
                }
                if case .approved = self.state { continue }  // terminal
                // Beats `.unanswered` too: a late approval is still an
                // approval.
                self.unansweredTask?.cancel()
                self.state = .approved(match)
            }
        }
    }
}
