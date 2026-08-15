import Foundation
import Observation

/// The seven first-launch steps, in presentation order.
public enum OnboardingStep: String, CaseIterable, Equatable, Hashable, Sendable {
    case welcome
    case discoveryConfirm
    case messageTransport
    case blobTransport
    case notary
    case moderation
    case done
}

/// What happened at one step, modeled abstractly — the flow never
/// links against the packages whose surfaces produce these outcomes
/// (OnymDiscovery's module consent, OnymModerationUI's mandate flow).
/// The app-layer step content (PR 3) reports back through this enum.
public enum StepOutcome: Equatable, Sendable {
    /// The user consented at this step. `componentId` names the chosen
    /// component when the step's surface knows one (catalog picks);
    /// nil for consents without a component identity (e.g. confirming
    /// the seeded discovery source).
    case consented(componentId: String?)
    /// The user skipped the step; the seat falls back to today's
    /// defaults.
    case skipped
    /// The step had nothing to decide (informational steps: welcome,
    /// done).
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

/// State machine for the first-launch onboarding sequence. Modeled on
/// `ModuleConsentFlow` / `ModerationConsentFlow`: `@MainActor
/// @Observable`, every collaborator injected as a closure so the
/// machine is unit-testable and the package stays dependency-free.
///
/// Presentation contract (PR 3): RootView presents `OnboardingView` as
/// a `fullScreenCover` with `.interactiveDismissDisabled(true)` — the
/// only exits are `complete()` on the Done step and the per-step Skip
/// affordances; there is no swipe-to-dismiss.
///
/// Partial progress is deliberately NOT persisted: the flow lives in
/// memory, and an app killed mid-onboarding starts over at `welcome`
/// on next launch. Individual consents the step content applied
/// before the kill are persisted by their own stores (consent pins,
/// mandate) — only the walk position restarts. Revisit in PR 3 if the
/// wired flow turns out long enough to warrant resume.
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

    /// Zero-based position of the current step, for the indicator.
    public var stepIndex: Int {
        OnboardingStep.allCases.firstIndex(of: step) ?? 0
    }

    /// Total number of steps (7), for the indicator.
    public var stepCount: Int {
        OnboardingStep.allCases.count
    }

    // MARK: - Skippability

    /// Every step is skippable except:
    /// - `welcome` — its primary Continue is the only path forward; a
    ///   separate Skip would be redundant (and the view never renders
    ///   one);
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
        switch step {
        case .welcome, .moderation, .done:
            return false
        default:
            return true
        }
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
    /// the distinct `.unavailable` outcome. Note this is deliberately
    /// NOT the complement of `isSkippable` anymore: moderation is
    /// never skippable in any state.
    public func isMandatory(_ step: OnboardingStep) -> Bool {
        guard step == .moderation else { return false }
        return moderationDirectoryHasEntries != false
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
    /// steps (welcome), except moderation over a RESOLVED-empty
    /// directory, whose Continue-only acknowledgment records the
    /// distinct `.unavailable` (moderation wasn't offered; the user
    /// did not opt out). No-op on `done` (`complete()` is the
    /// terminal action), and a no-op on a mandatory step with no
    /// recorded outcome — the primary button must not be a back door
    /// around the must-consent moderation rule (the view also
    /// disables it; this guard is the second layer).
    public func advance() {
        guard let next = neighbor(offset: 1) else { return }
        guard !isMandatory(step) || outcomes[step] != nil else { return }
        if outcomes[step] == nil {
            outcomes[step] = step == .moderation && moderationDirectoryHasEntries == false
                ? .unavailable
                : .notApplicable
        }
        step = next
    }

    /// Skip the current step, recording `.skipped`. Guarded by
    /// `isSkippable` — a no-op on an unskippable step (moderation with
    /// a non-empty directory, done).
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

    /// "Start" on the Done step: persist the completion flag, then let
    /// the presenter dismiss. Guarded to the `done` step so no
    /// programming error can mark onboarding complete mid-sequence.
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
