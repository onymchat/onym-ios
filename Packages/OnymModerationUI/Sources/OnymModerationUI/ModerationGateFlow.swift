import Foundation
import OnymModeration

/// Why the re-consent surface is up — the two cases differ in what the
/// user can actually do about it.
public enum ReconsentReason: Equatable, Sendable {
    /// The authority publishes a new manifest. Re-signing with the same
    /// authority is available, and is the expected answer.
    case termsChanged
    /// The authority left the directory. There is nothing to re-sign;
    /// only another authority will do.
    case authorityDelisted
}

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
        /// The active mandate's terms are no longer the ones its
        /// authority publishes: re-sign or move (blocking).
        case needsReconsent(ReconsentReason)
        /// Operating; non-empty `openCases` shows the case banner.
        case operational(openCases: [CaseNotice])
    }

    public private(set) var gate: RootGate = .checking

    private let moderation: ModerationRepository
    private let gateCheck: GateCheckRepository
    private var moderationTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?
    private var termsTask: Task<Void, Never>?

    private var hasMandate: Bool?
    private var authoritiesAvailable = false
    private var gateStatus: GateStatus?
    private var termsCurrency: TermsCurrency = .unknown

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
                self.termsCurrency = state.termsCurrency
                self.recompute()
            }
        }
        // App open is the first of the two moments the terms check
        // runs; `appForegrounded` is the other. Tracked like the two
        // drains above so `stop()` cancels it and a repeated `start()`
        // doesn't re-fire it.
        termsTask = Task { [weak self] in
            await self?.moderation.refreshActiveTerms()
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
        termsTask?.cancel()
        termsTask = nil
    }

    // MARK: - Intents

    /// Retry button on the check-required screen.
    public func tappedRetry() async {
        await gateCheck.checkNow()
    }

    /// The consent flow finished — run the first gate check for the
    /// fresh mandate immediately instead of waiting for the interval.
    public func consentCompleted() {
        Task { await gateCheck.checkNow() }
    }

    /// App returned to foreground: refresh the gate (covers the P1D
    /// cadence across relaunches and long backgrounding) and re-read
    /// the authority's published manifest, which is how terms changed
    /// while the app was away get noticed.
    public func appForegrounded() {
        Task { await gateCheck.checkNow() }
        // Same handle as the launch check: the repository coalesces
        // overlapping checks anyway, so this only keeps `stop()` able to
        // drop the flow's interest in the newest one.
        termsTask = Task { [weak self] in
            await self?.moderation.refreshActiveTerms()
        }
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
            // Stale consent gates an otherwise operating app, and only
            // there. It deliberately ranks below every enforcement
            // answer: a banned user re-signing terms is still banned,
            // and an unanswered gate check is the more urgent block.
            // It also never pre-empts `.checking` — a re-consent screen
            // thrown up before the gate has spoken would be the first
            // thing a cold launch shows on a flaky network.
            switch termsCurrency {
            case .superseded:
                gate = .needsReconsent(.termsChanged)
            case .authorityDelisted:
                // A directory that lists nobody leaves the user no move
                // to make; the same reasoning that keeps consent from
                // bricking an install on an empty directory applies.
                gate = authoritiesAvailable
                    ? .needsReconsent(.authorityDelisted)
                    : .operational(openCases: openCases)
            case .current, .unknown:
                gate = .operational(openCases: openCases)
            }
        case .banned(let state):
            gate = .banned(state)
        case .gateCheckRequired(.enrollmentLost):
            // The backend has no record of this device's enrollment —
            // retrying cannot succeed. Consent IS the recovery: it
            // re-runs enrollment, countersignature, and registration,
            // so route there instead of a dead-ended retry screen.
            //
            // The no-authorities softening from the `!hasMandate`
            // branch does NOT transfer here: an active mandate proves
            // an authority was designated, so a directory that hasn't
            // loaded (cold launch, rate limit, fetch failure) is a
            // transient outage, not evidence this install answers to
            // no one. Falling back to operational would let a
            // reachable backend's `no_mandate` answer run the app
            // unmoderated for as long as the directory stays down —
            // so without authorities this blocks on the (normally
            // unreachable) check-required screen instead.
            gate = authoritiesAvailable ? .needsConsent : .gateCheckRequired(.enrollmentLost)
        case .gateCheckRequired(let reason):
            gate = .gateCheckRequired(reason)
        }
    }
}
