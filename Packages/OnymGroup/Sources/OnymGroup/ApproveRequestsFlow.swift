import Foundation
import Observation

/// `@Observable @MainActor` view-model for the approver UI. Mirrors
/// `IdentitiesFlow`'s posture — one shared instance lives in
/// `AppDependencies`. `ChatsView` reads `pending` for the per-group
/// chat-list signal, and each group's `ChatThreadView` renders its own
/// slice of the list as in-thread rows that dispatch Accept / Decline.
/// (Both surfaces used to be one modal + toolbar badge; the requests
/// moved into the thread because nobody found the badge.)
///
/// Purely a thin wrapper over `JoinRequestApprover` — no UI logic
/// beyond mapping `ApproveOutcome` to a user-facing reason string.
/// `start()` is idempotent so any view's `.task` can call it without
/// double-subscribing.
@MainActor
@Observable
public final class ApproveRequestsFlow {
    /// Decoded pending requests, newest-first.
    public private(set) var pending: [JoinRequestApprover.PendingRequest] = []
    /// Last failed-approve reason, or nil. Cleared on the next
    /// successful Approve / Decline / dismiss.
    public internal(set) var lastError: String?
    /// Which request `lastError` belongs to. The thread renders each
    /// pending request as its own row, so an un-keyed error would paint
    /// a failure from one request onto every other row on screen.
    public internal(set) var lastErrorRequestID: String?
    /// Request IDs whose Approve / Decline call is currently in
    /// flight. Drives the per-row spinner + disabled-buttons state
    /// in the thread's join-request row. Necessary because PR 13a turned
    /// `approve` into a multi-second flow (PLONK prove +
    /// `update_commitment` HTTP roundtrip + Stellar tx wait) — without
    /// this signal the UI looks frozen while the proof generates.
    var inFlightRequestIDs: Set<String> = []

    private let approver: any JoinRequestApproving
    private var streamingTask: Task<Void, Never>?

    public init(approver: any JoinRequestApproving) {
        self.approver = approver
    }

    /// True when the row for `requestID` should render as
    /// in-flight (spinner + disabled). Helper so views don't have
    /// to reach into the `Set` directly.
    public func isInFlight(_ requestID: String) -> Bool {
        inFlightRequestIDs.contains(requestID)
    }

    /// Start the underlying collector + mirror `pending` snapshots
    /// into the @Observable property. Idempotent.
    public func start() async {
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

    public func approve(_ id: String) {
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
            guard let self else { return }
            self.inFlightRequestIDs.remove(id)
            switch outcome {
            case .sent:
                // No success banner: the confirmation is now the "X
                // joined" system message the approval itself writes into
                // the thread, right where the request row was.
                //
                // Only clears the error if it belonged to *this* request.
                // The whole point of keying it was that the thread shows
                // one row per request — wiping unconditionally would make
                // approving A erase the failure still displayed under B.
                self.clearErrorIfOwned(by: id)
            default:
                self.lastError = Self.failureReason(for: outcome)
                self.lastErrorRequestID = id
            }
        }
    }

    public func decline(_ id: String) {
        guard !inFlightRequestIDs.contains(id) else { return }
        inFlightRequestIDs.insert(id)
        let approver = self.approver
        Task { @MainActor [weak self] in
            await approver.decline(requestId: id)
            self?.inFlightRequestIDs.remove(id)
            self?.clearErrorIfOwned(by: id)
        }
    }

    /// Drop `lastError` only when it belongs to `id`. Acting on one
    /// request must not clear the error another row is still showing.
    private func clearErrorIfOwned(by id: String) {
        guard lastErrorRequestID == id || lastErrorRequestID == nil else { return }
        lastError = nil
        lastErrorRequestID = nil
    }

    public func dismissError() {
        lastError = nil
        lastErrorRequestID = nil
    }

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
            return "No Founder contract selected for this network. Pick one in Settings \u{2192} Network \u{2192} Anchors."
        case .notAdminOfThisGroup:
            return "The active identity isn\u{2019}t this group\u{2019}s admin. Switch to the identity that created the group, then try again."
        case .proofFailed(let reason):
            return "Couldn\u{2019}t generate proof: \(reason)"
        case .anchorRejected(let reason):
            return "Chain rejected the proof: \(reason)"
        }
    }
}
