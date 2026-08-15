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
    /// done, moderation-with-empty-directory).
    case notApplicable
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
    /// `start()` via the injected probe. Until (or unless) the probe
    /// answers true, moderation behaves as skippable/informational,
    /// matching today's gate semantics (empty directory ⇒ the gate
    /// reads operational and never blocks).
    public private(set) var moderationDirectoryHasEntries = false

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
    /// - `moderation` when the authority directory has entries — the
    ///   moderation gate would block right after onboarding anyway, so
    ///   letting the user skip here would be a lie (this mirrors the
    ///   existing gate: consent is only optional while the directory
    ///   is empty/operational);
    /// - `done`, which is terminal — there is nothing after it to skip
    ///   to (its primary action is `complete()`).
    public func isSkippable(_ step: OnboardingStep) -> Bool {
        switch step {
        case .moderation:
            return !moderationDirectoryHasEntries
        case .done:
            return false
        default:
            return true
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
    /// outcome is backfilled as `.notApplicable` — the informational
    /// steps (welcome; moderation with an empty directory) advance
    /// through here without ever recording. No-op on `done`
    /// (`complete()` is the terminal action).
    public func advance() {
        guard let next = neighbor(offset: 1) else { return }
        if outcomes[step] == nil {
            outcomes[step] = .notApplicable
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
