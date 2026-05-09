import Foundation
import Observation

/// `@Observable @MainActor` view-model for the approver UI. Mirrors
/// `IdentitiesFlow`'s posture — one shared instance lives in
/// `AppDependencies`, the toolbar badge on `ChatsView` watches
/// `pending.count`, and the modal `ApproveRequestsView` consumes the
/// full list + dispatches Approve / Decline taps.
///
/// Purely a thin wrapper over `JoinRequestApprover` — no UI logic
/// beyond mapping `ApproveOutcome` to a user-facing reason string.
/// `start()` is idempotent so any view's `.task` can call it without
/// double-subscribing.
@MainActor
@Observable
final class ApproveRequestsFlow {
    /// Decoded pending requests, newest-first.
    var pending: [JoinRequestApprover.PendingRequest] = []
    /// Last failed-approve reason, or nil. Cleared on the next
    /// successful Approve / Decline / dismiss.
    var lastError: String?

    private let approver: any JoinRequestApproving
    private var streamingTask: Task<Void, Never>?

    init(approver: any JoinRequestApproving) {
        self.approver = approver
    }

    /// Start the underlying collector + mirror `pending` snapshots
    /// into the @Observable property. Idempotent.
    func start() async {
        guard streamingTask == nil else { return }
        await approver.start()
        let stream = approver.pending
        streamingTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self else { break }
                self.pending = snapshot
            }
        }
    }

    /// Cancel observation. The approver's collector keeps running so
    /// the next `start()` re-attaches without losing requests that
    /// arrived in the gap.
    func stop() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    func approve(_ id: String) {
        let approver = self.approver
        Task { @MainActor [weak self] in
            let outcome = await approver.approve(requestId: id)
            self?.lastError = Self.failureReason(for: outcome)
        }
    }

    func decline(_ id: String) {
        let approver = self.approver
        Task { @MainActor [weak self] in
            await approver.decline(requestId: id)
            self?.lastError = nil
        }
    }

    func dismissError() { lastError = nil }

    private static func failureReason(
        for outcome: JoinRequestApprover.ApproveOutcome
    ) -> String? {
        switch outcome {
        case .sent: return nil
        case .unknownGroup:
            return "This invite isn\u{2019}t for any group on this device."
        case .unknownRequest:
            return "Request expired or was already handled."
        case .noIdentityLoaded:
            return "Sign in first."
        case .transportFailed(let reason):
            return "Couldn\u{2019}t send: \(reason)"
        case .outdatedJoinerClient:
            return "Joiner is on an outdated app. Ask them to update."
        case .noActiveRelayer:
            return "No chain relayer configured. Set one in Settings \u{2192} Network \u{2192} Relayer."
        case .noContractBinding:
            return "No Tyranny contract selected for this network. Pick one in Settings \u{2192} Network \u{2192} Anchors."
        case .proofFailed(let reason):
            return "Couldn\u{2019}t generate proof: \(reason)"
        case .anchorRejected(let reason):
            return "Chain rejected the proof: \(reason)"
        }
    }
}
