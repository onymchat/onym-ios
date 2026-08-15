import Foundation
import Observation

/// The first-launch steps, in presentation order. The user-facing
/// story is "three steps" — identity, services, reports & safety —
/// bracketed by an unnumbered welcome, the recovery-phrase backup,
/// and the closing summary. `indicatorPosition(for:)` reflects that:
/// only the three core steps carry a position.
public enum OnboardingStep: String, CaseIterable, Equatable, Hashable, Sendable {
    case welcome
    /// "Making your keys" — identity creation status. Informational:
    /// the bootstrap already runs at app start; this step shows it.
    case identity
    /// "Your services" — the recommended-setup card, with the
    /// "choose services myself" hub as an in-step branch. Collapses
    /// the old discoveryConfirm / messageTransport / blobTransport /
    /// notary wizard steps.
    case services
    /// "Reports & safety" — the moderation-authority pick + mandate.
    case moderation
    /// "Save your recovery phrase" — the backup reveal, promoted from
    /// the old Done-step footnote nudge.
    case recoveryPhrase
    case done
}

/// What happened at one step, modeled abstractly — the flow never
/// links against the packages whose surfaces produce these outcomes
/// (OnymDiscovery's module consent, OnymModerationUI's mandate flow).
/// The app-layer step content reports back through this enum.
public enum StepOutcome: Equatable, Sendable {
    /// The user consented at this step. `componentId` names the chosen
    /// component when the step's surface knows one (catalog picks);
    /// nil for consents without a component identity (accepting the
    /// recommended setup, confirming a source, backing up the phrase).
    case consented(componentId: String?)
    /// The user skipped the step; the seat falls back to today's
    /// defaults. Only the recovery-phrase step is skippable now
    /// ("Remind me later") — Settings keeps nudging until backed up.
    case skipped
    /// The step had nothing to decide (informational steps: welcome,
    /// identity, done).
    case notApplicable
    /// The step's obligation exists but could not be offered — today
    /// exactly moderation with an EMPTY authority directory: there is
    /// no authority to pick, so the user acknowledges with Continue.
    /// Distinct from `.skipped` (a choice the user declined to make)
    /// and `.notApplicable` (nothing to decide at all) so downstream
    /// state never mistakes "moderation wasn't available" for
    /// "the user opted out" — opting out of moderation is not a thing.
    case unavailable
}

/// How far the recovery-phrase backup got. Lives on the flow (not the
/// step view) for the same reason as `ServicesSetupChoice`: the step
/// body is rebuilt on every navigation, and the status card must not
/// reset to "Not backed up yet" after Back from Done. Also what lets
/// the Done summary tell "saw the words" apart from "verified them".
public enum RecoveryBackupState: Equatable, Sendable {
    /// The phrase was never shown.
    case none
    /// The words were on screen — enough to honestly tap "I've
    /// written it down", not enough to claim a verified backup.
    case revealed
    /// The reveal + verify quiz completed.
    case verified
}

/// Which path the services step is on. Lives on the flow (not the step
/// view) so the selection survives Back/forward navigation — the step
/// body derives its "Selected" chip from this, never from view-local
/// state.
public enum ServicesSetupChoice: Equatable, Sendable {
    /// The preselected default: seeded services plus the published
    /// lists installed on completion.
    case recommended
    /// The user went through the "choose services myself" hub.
    case custom
}

/// State machine for the first-launch onboarding sequence. Modeled on
/// `ModuleConsentFlow` / `ModerationConsentFlow`: `@MainActor
/// @Observable`, every collaborator injected as a closure so the
/// machine is unit-testable and the package stays dependency-free.
///
/// Presentation contract: RootView presents `OnboardingView` as a
/// `fullScreenCover` with `.interactiveDismissDisabled(true)` — the
/// only exits are `complete()` on the Done step and the recovery
/// step's "Remind me later"; there is no swipe-to-dismiss.
///
/// Partial progress is deliberately NOT persisted: the flow lives in
/// memory, and an app killed mid-onboarding starts over at `welcome`
/// on next launch. Individual consents the step content applied
/// before the kill are persisted by their own stores (consent pins,
/// mandate) — only the walk position restarts.
@MainActor
@Observable
public final class OnboardingFlow {
    public private(set) var step: OnboardingStep = .welcome
    /// Per-step record of what the user decided. Written by
    /// `recordOutcome` (step content reporting a consent), `skip()`
    /// (`.skipped`), and `advance()` (backfills `.notApplicable` for
    /// steps that were walked past without a decision). Revisiting a
    /// step via `back()` keeps the prior outcome until a new one is
    /// recorded over it.
    public private(set) var outcomes: [OnboardingStep: StepOutcome] = [:]
    /// Whether the moderation directory has entries — resolved once by
    /// `start()` via the injected probe. Tri-state and FAIL-CLOSED:
    /// nil (unresolved) is treated exactly like "has entries" — the
    /// moderation step reads unskippable/mandatory until the probe
    /// answers `false`. Racing the probe must never open a skip window
    /// that a resolved `true` would have closed.
    public private(set) var moderationDirectoryHasEntries: Bool?
    /// The services step's path, written by its step content. On the
    /// flow (not the step view) so Back/forward navigation can't reset
    /// the selection chip to a state that contradicts what the user
    /// actually configured.
    public var servicesChoice: ServicesSetupChoice = .recommended
    /// How far the recovery backup got, written by the recovery step's
    /// content as the backup sheet progresses. Never downgrades:
    /// `verified` stays `verified` across navigation and re-reveals.
    public var recoveryBackupState: RecoveryBackupState = .none
    /// Flips exactly once, inside `complete()` — the observable signal
    /// the presenter dismisses its cover on. `onCompleted` alone can't
    /// carry the dismissal: it is bound at the composition root, which
    /// has no handle on the presenting view's state.
    public private(set) var isCompleted = false

    /// Whether the directory probe has answered — the view shows a
    /// progress state on the skip affordance while this is false.
    public var moderationProbeResolved: Bool {
        moderationDirectoryHasEntries != nil
    }

    private let store: any OnboardingStore
    private let moderationDirectoryNonEmpty: () async -> Bool
    /// Called after `complete()` writes the flag, so the presenter can
    /// dismiss the cover and hand control to the moderation gate.
    private let onCompleted: @MainActor () -> Void
    /// The in-flight directory probe, internal so tests can await it.
    @ObservationIgnored private(set) var moderationProbeTask: Task<Void, Never>?

    public init(
        store: any OnboardingStore,
        moderationDirectoryNonEmpty: @escaping () async -> Bool,
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.moderationDirectoryNonEmpty = moderationDirectoryNonEmpty
        self.onCompleted = onCompleted
    }

    // MARK: - Step indicator

    /// The three steps the indicator counts — the user-facing "step N
    /// of 3". Welcome, the recovery phrase, and Done are unnumbered.
    private static let indicatorSteps: [OnboardingStep] = [.identity, .services, .moderation]

    /// Zero-based indicator position for a step, or nil when the step
    /// carries no indicator (welcome, recoveryPhrase, done).
    public func indicatorPosition(for step: OnboardingStep) -> (index: Int, count: Int)? {
        guard let index = Self.indicatorSteps.firstIndex(of: step) else { return nil }
        return (index, Self.indicatorSteps.count)
    }

    // MARK: - Skippability

    /// Only the recovery-phrase step is skippable ("Remind me later"):
    /// - `welcome`, `identity`, `services` — their primary Continue is
    ///   the only path forward; the recommended setup IS the default,
    ///   so a separate Skip would be redundant;
    /// - `moderation` — NEVER skippable, in any directory state.
    ///   Moderation-authority selection is not optional: with entries
    ///   present the user must pick and sign (the gate would block
    ///   right after onboarding anyway), and with an EMPTY directory
    ///   there is nothing to decline — the step turns Continue-only
    ///   informational instead (`isMandatory` answers false and
    ///   `advance()` records `.unavailable`), which is an
    ///   acknowledgment, not a skip;
    /// - `done`, which is terminal — there is nothing after it to skip
    ///   to (its primary action is `complete()`).
    public func isSkippable(_ step: OnboardingStep) -> Bool {
        step == .recoveryPhrase
    }

    /// A mandatory step cannot be walked past without a recorded
    /// outcome — `advance()` refuses until the step content reports
    /// one. Today that is exactly `moderation` while the directory has
    /// entries (or the probe hasn't answered yet — fail-closed): its
    /// consent is the one obligation onboarding must not silently
    /// drop, because the gate behind it would block anyway. Only a
    /// RESOLVED-empty directory relaxes this — there is no authority
    /// to pick, so hard-blocking would brick onboarding; the step
    /// becomes Continue-only informational and `advance()` records
    /// the distinct `.unavailable` outcome.
    public func isMandatory(_ step: OnboardingStep) -> Bool {
        guard step == .moderation else { return false }
        return moderationDirectoryHasEntries != false
    }

    /// A step whose primary refuses to advance without a recorded
    /// outcome (the view disables the button; `advance()` carries the
    /// same guard as the second layer):
    /// - `identity` always — its content records once the key
    ///   bootstrap actually produced a snapshot; a failed bootstrap
    ///   must not walk the user on to services and a recovery step
    ///   whose reveal cannot work;
    /// - `moderation` while mandatory (see `isMandatory`);
    /// - `recoveryPhrase` always — its primary reads "I've written it
    ///   down", which must not be tappable before the phrase was ever
    ///   revealed. The step content records the outcome on reveal;
    ///   "Remind me later" (skip) is the honest escape.
    public func requiresOutcomeToAdvance(_ step: OnboardingStep) -> Bool {
        switch step {
        case .identity: return true
        case .moderation: return isMandatory(step)
        case .recoveryPhrase: return true
        default: return false
        }
    }

    /// Whether the recorded outcome actually satisfies an
    /// outcome-gated step. `.skipped` deliberately does NOT: skipping
    /// records a decision, but revisiting the step must re-gate its
    /// primary — an earlier "Remind me later" must never leave
    /// "I've written it down" enabled over a phrase that was never
    /// revealed. The honest exits from a re-gated step are the same
    /// as the first visit: satisfy the gate, or skip again.
    public func outcomeSatisfiesGate(_ step: OnboardingStep) -> Bool {
        switch outcomes[step] {
        case nil, .skipped?: return false
        default: return true
        }
    }

    // MARK: - Lifecycle

    /// Kick the async moderation-directory probe. Idempotent.
    public func start() {
        guard moderationProbeTask == nil else { return }
        moderationProbeTask = Task { [weak self] in
            guard let self else { return }
            let nonEmpty = await self.moderationDirectoryNonEmpty()
            self.moderationDirectoryHasEntries = nonEmpty
        }
    }

    /// Step content reports what the user decided at the current step.
    /// Recording again overwrites (the user changed their mind before
    /// advancing, or came `back()` and redid the step).
    public func recordOutcome(_ outcome: StepOutcome) {
        outcomes[step] = outcome
    }

    /// Move to the next step. A step walked past without any recorded
    /// outcome is backfilled — `.notApplicable` for the informational
    /// steps, except moderation over a RESOLVED-empty directory, whose
    /// Continue-only acknowledgment records the distinct
    /// `.unavailable` (moderation wasn't offered; the user did not opt
    /// out). No-op on `done` (`complete()` is the terminal action),
    /// and a no-op on a step that requires an outcome and has none —
    /// the primary button must not be a back door around the
    /// must-consent moderation rule or the must-reveal recovery rule
    /// (the view also disables it; this guard is the second layer).
    public func advance() {
        guard let next = neighbor(offset: 1) else { return }
        guard !requiresOutcomeToAdvance(step) || outcomeSatisfiesGate(step) else { return }
        if outcomes[step] == nil {
            outcomes[step] = step == .moderation && moderationDirectoryHasEntries == false
                ? .unavailable
                : .notApplicable
        }
        step = next
    }

    /// Skip the current step, recording `.skipped`. Guarded by
    /// `isSkippable` — a no-op on every step except recoveryPhrase.
    public func skip() {
        guard isSkippable(step), let next = neighbor(offset: 1) else { return }
        outcomes[step] = .skipped
        step = next
    }

    /// Move to the previous step. No-op on `welcome`. The revisited
    /// step's prior outcome is kept — `recordOutcome` / `skip()`
    /// overwrite it if the user decides differently this time.
    public func back() {
        guard let previous = neighbor(offset: -1) else { return }
        step = previous
    }

    /// "Start messaging" on the Done step: persist the completion
    /// flag, then let the presenter dismiss. Guarded to the `done`
    /// step so no programming error can mark onboarding complete
    /// mid-sequence.
    public func complete() {
        guard step == .done else { return }
        if outcomes[step] == nil {
            outcomes[step] = .notApplicable
        }
        store.markOnboardingCompleted()
        isCompleted = true
        onCompleted()
    }

    // MARK: - Private

    private func neighbor(offset: Int) -> OnboardingStep? {
        let all = OnboardingStep.allCases
        guard let index = all.firstIndex(of: step) else { return nil }
        let target = index + offset
        guard all.indices.contains(target) else { return nil }
        return all[target]
    }
}
