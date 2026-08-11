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
    /// Why each request's last Approve failed, keyed by request id.
    ///
    /// A map rather than a single slot because the thread renders one
    /// row per pending request: with two outstanding failures, a single
    /// slot could only ever explain the newer one, and the older row
    /// would silently lose its explanation while its request was still
    /// there to retry. Each row reads its own entry, so an unrelated
    /// failure can neither overwrite nor leak onto it.
    public internal(set) var errors: [String: String] = [:]
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
        // Clear this request's failure as the retry starts, not when it
        // succeeds. Waiting for `.sent` rendered the spinner and the
        // previous error together — "Anchoring on chain…" under "that
        // didn't work" — which reads as a fresh failure rather than a
        // stale one.
        clearError(for: id)
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
                // Nothing to clear: this request's error went when the
                // attempt started.
                break
            default:
                self.errors[id] = Self.failureReason(for: outcome)
            }
        }
    }

    public func decline(_ id: String) {
        guard !inFlightRequestIDs.contains(id) else { return }
        inFlightRequestIDs.insert(id)
        // Same reasoning as `approve`: the error goes when the action
        // starts, so the row never shows a spinner over a stale failure.
        clearError(for: id)
        let approver = self.approver
        Task { @MainActor [weak self] in
            await approver.decline(requestId: id)
            self?.inFlightRequestIDs.remove(id)
        }
    }

    /// This request's last failure, if it has one. Each row reads its
    /// own; nothing else can surface on it.
    public func error(for requestID: String) -> String? {
        errors[requestID]
    }

    /// Drop one request's error. Keyed, so acting on one request cannot
    /// clear the explanation another row is still showing. A request's
    /// error goes when that request is acted on again — retried or
    /// declined — and not before.
    ///
    /// There is deliberately no dismiss affordance now that the modal is
    /// gone: the error sits on the row it belongs to, and the row is the
    /// thing the founder is going to touch next. A `dismissError()` used
    /// to exist for the modal's toolbar and had no caller left, so it
    /// went rather than sitting there looking like an API.
    private func clearError(for id: String) {
        errors.removeValue(forKey: id)
    }

    /// These render on the request row in the thread, next to copy that
    /// all resolves through the app's string catalog — so they go
    /// through it too. They used to sit behind a modal and were raw
    /// English; `ChatSystemEvent.localizedText` makes the same point for
    /// the notice text.
    private static func failureReason(
        for outcome: JoinRequestApprover.ApproveOutcome
    ) -> String? {
        switch outcome {
        case .sent: return nil
        case .unknownGroup:
            return String(localized: "This invite isn’t for any group on this device.")
        case .unknownRequest:
            return String(localized: "Request expired or was already handled.")
        case .noIdentityLoaded:
            return String(localized: "Sign in first.")
        case .transportFailed(let reason):
            return String(localized: "Couldn’t send: \(reason)")
        case .outdatedJoinerClient:
            return String(localized: "Joiner is on an outdated app. Ask them to update.")
        case .noActiveRelayer:
            return String(
                localized: "No chain relayer configured. Set one in Settings → Network → Relayer."
            )
        case .noContractBinding:
            return String(
                localized: "No Founder contract selected for this network. Pick one in Settings → Network → Anchors."
            )
        case .notAdminOfThisGroup:
            return String(
                localized: "The active identity isn’t this group’s admin. Switch to the identity that created the group, then try again."
            )
        case .proofFailed(let reason):
            return String(localized: "Couldn’t generate proof: \(reason)")
        case .anchorRejected(let reason):
            return String(localized: "Chain rejected the proof: \(reason)")
        }
    }
}
