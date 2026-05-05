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
    /// Request IDs whose Approve / Decline call is currently in
    /// flight. Drives the per-row spinner + disabled-buttons state
    /// in `ApproveRequestsView`. Necessary because PR 13a turned
    /// `approve` into a multi-second flow (PLONK prove +
    /// `update_commitment` HTTP roundtrip + Stellar tx wait) — without
    /// this signal the UI looks frozen while the proof generates.
    var inFlightRequestIDs: Set<String> = []

    private let approver: any JoinRequestApproving
    private var streamingTask: Task<Void, Never>?

    init(approver: any JoinRequestApproving) {
        self.approver = approver
    }

    /// True when the row for `requestID` should render as
    /// in-flight (spinner + disabled). Helper so views don't have
    /// to reach into the `Set` directly.
    func isInFlight(_ requestID: String) -> Bool {
        inFlightRequestIDs.contains(requestID)
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
        // Debounce: a second tap while the first call is in flight
        // is a no-op. `approver.approve` is idempotent on requestID
        // (already-consumed requests return `.unknownRequest`), but
        // re-entering the proof+chain submission path twice is a
        // waste of cycles + can confuse `lastError` ordering.
        guard !inFlightRequestIDs.contains(id) else { return }
        inFlightRequestIDs.insert(id)
        let approver = self.approver
        Task { @MainActor [weak self] in
            let outcome = await approver.approve(requestId: id)
            self?.inFlightRequestIDs.remove(id)
            self?.lastError = Self.failureReason(for: outcome)
        }
    }

    func decline(_ id: String) {
        guard !inFlightRequestIDs.contains(id) else { return }
        inFlightRequestIDs.insert(id)
        let approver = self.approver
        Task { @MainActor [weak self] in
            await approver.decline(requestId: id)
            self?.inFlightRequestIDs.remove(id)
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
