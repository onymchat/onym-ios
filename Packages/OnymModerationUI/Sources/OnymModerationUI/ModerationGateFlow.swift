import Foundation
import OnymModeration

/// Merges `ModerationRepository` and `GateCheckRepository` snapshots
/// into the single state the app root switches on. The root gate is
/// the enforcement surface: consent before use, ban screen on bit1,
/// blocking check-required when no trustworthy gate answer exists.
@MainActor
@Observable
public final class ModerationGateFlow {
    public enum RootGate: Equatable {
        /// Repositories haven't reported yet. The app renders normally
        /// in this state — see `recompute`, which explains why blocking
        /// launch on the first gate answer waits on a real backend.
        case checking
        /// No active mandate: present the consent flow (blocking).
        case needsConsent
        /// bit1 — the app refuses to operate (blocking).
        case banned(BanState)
        /// No trustworthy gate answer and grace exhausted (blocking).
        case gateCheckRequired(CheckRequiredReason)
        /// Operating; non-empty `openCases` shows the case banner.
        case operational(openCases: [CaseNotice])
    }

    public private(set) var gate: RootGate = .checking

    private let moderation: ModerationRepository
    private let gateCheck: GateCheckRepository
    private var moderationTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?

    private var hasMandate: Bool?
    private var authoritiesAvailable = false
    private var gateStatus: GateStatus?

    public init(moderation: ModerationRepository, gateCheck: GateCheckRepository) {
        self.moderation = moderation
        self.gateCheck = gateCheck
    }

    /// Begin draining both repositories. Idempotent.
    public func start() {
        guard moderationTask == nil else { return }
        moderationTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.moderation.snapshots {
                self.hasMandate = state.activeMandate != nil
                self.authoritiesAvailable = !state.authorities.isEmpty
                self.recompute()
            }
        }
        gateTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.gateCheck.snapshots {
                self.gateStatus = status
                self.recompute()
            }
        }
    }

    public func stop() {
        moderationTask?.cancel()
        moderationTask = nil
        gateTask?.cancel()
        gateTask = nil
    }

    // MARK: - Intents

    /// Retry button on the check-required screen.
    public func tappedRetry() {
        Task { await gateCheck.checkNow() }
    }

    /// The consent flow finished — run the first gate check for the
    /// fresh mandate immediately instead of waiting for the interval.
    public func consentCompleted() {
        Task { await gateCheck.checkNow() }
    }

    /// App returned to foreground: refresh the gate (covers the P1D
    /// cadence across relaunches and long backgrounding).
    public func appForegrounded() {
        Task { await gateCheck.checkNow() }
    }

    // MARK: - Private

    /// Consent outranks the gate: with no mandate the only lawful
    /// screen is the consent surface (the gate repository reports
    /// `.notMandated` and makes no backend calls). With a mandate,
    /// the gate status governs.
    ///
    /// Two deliberate softenings while no real moderation stack is
    /// deployed:
    /// - **No authorities, no gate.** The consent screen only blocks
    ///   when the designated-authorities directory actually yields
    ///   entries. An interface without a designated authority answers
    ///   to its distribution channel, not this contract (Moderation.md
    ///   §11.12) — and bricking every install on an unpublished
    ///   directory would be a self-inflicted outage.
    /// - **`.checking` renders the app.** Blocking launch on the first
    ///   gate answer only makes sense against a real backend; until
    ///   then enforcement applies the moment a definitive status
    ///   arrives.
    private func recompute() {
        guard let hasMandate else { return }
        if !hasMandate {
            gate = authoritiesAvailable ? .needsConsent : .operational(openCases: [])
            return
        }
        switch gateStatus {
        case nil, .notMandated:
            // Mandate exists but the gate hasn't answered yet.
            gate = .checking
        case .operational(let openCases):
            gate = .operational(openCases: openCases)
        case .banned(let state):
            gate = .banned(state)
        case .gateCheckRequired(.enrollmentLost):
            // The backend has no record of this device's enrollment —
            // retrying cannot succeed. Consent IS the recovery: it
            // re-runs enrollment, countersignature, and registration,
            // so route there instead of a dead-ended retry screen.
            gate = authoritiesAvailable ? .needsConsent : .operational(openCases: [])
        case .gateCheckRequired(let reason):
            gate = .gateCheckRequired(reason)
        }
    }
}
