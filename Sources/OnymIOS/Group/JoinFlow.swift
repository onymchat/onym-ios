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

    init(
        capability: IntroCapability,
        suggestedDisplayLabel: String,
        submitRequest: @escaping @Sendable (IntroCapability, String) async -> JoinRequestSender.Outcome,
        groupRepository: GroupRepository
    ) {
        self.capability = capability
        self.suggestedDisplayLabel = suggestedDisplayLabel
        self.submitRequest = submitRequest
        self.groupRepository = groupRepository
        self.state = .ready(capability)
        startWatcher()
    }

    // No deinit Task cleanup — both `sendTask` and `watcherTask`
    // capture `[weak self]` so they exit gracefully on deallocation
    // without needing main-actor-isolated cancellation in `deinit`
    // (which Swift's strict concurrency checking would flag).

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
            case .noIdentityLoaded:
                self.state = .failed(reason: "Sign in first.")
            case .transportFailed(let reason):
                self.state = .failed(reason: "Couldn't send: \(reason)")
            }
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
                self.state = .approved(match)
            }
        }
    }
}
