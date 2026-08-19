import SwiftUI

/// The first-launch onboarding cover: one scaffolded screen per
/// `OnboardingStep`, driven by `OnboardingFlow`.
///
/// Presentation contract: RootView presents this as a
/// `fullScreenCover` with `.interactiveDismissDisabled(true)` applied
/// at the presentation site — a full-screen cover has no interactive
/// dismissal of its own, but the modifier documents intent and guards
/// against a future switch to `.sheet`. The only exits are
/// `flow.complete()` on the Done step and the recovery step's
/// "Remind me later"; onboarding is never swiped away half-done.
///
/// Dependency posture: this package renders the *frame* of each step.
/// The middle steps' real content — the services hub, the moderation
/// mandate flow, the recovery-phrase reveal — lives at the app layer
/// and arrives through `stepContent`, so this view stays free of
/// OnymDiscovery / OnymModerationUI / OnymDesign / OnymRecovery.
/// Likewise the step indicator arrives through `stepIndicator`; the
/// default is a plain dot indicator so the package previews and tests
/// stand alone.
public struct OnboardingView: View {
    @State private var flow: OnboardingFlow
    /// App-supplied content slot, consulted for EVERY step (Welcome
    /// and Done included). Return nil to fall back to the built-ins:
    /// the Welcome/Done bodies, and a placeholder card for the middle
    /// steps.
    private let stepContent: (OnboardingStep) -> AnyView?
    /// App-supplied step indicator, given (zero-based index, count).
    /// Only rendered on the steps the indicator counts — the three
    /// core steps; welcome, recoveryPhrase and done are unnumbered.
    private let stepIndicator: (Int, Int) -> AnyView

    public init(
        flow: OnboardingFlow,
        stepContent: ((OnboardingStep) -> AnyView?)? = nil,
        stepIndicator: ((Int, Int) -> AnyView)? = nil
    ) {
        _flow = State(initialValue: flow)
        self.stepContent = stepContent ?? { _ in nil }
        self.stepIndicator = stepIndicator ?? { index, count in
            AnyView(DefaultStepIndicator(index: index, count: count))
        }
    }

    public var body: some View {
        scaffold(for: flow.step)
            .task { flow.start() }
    }

    // MARK: - Steps

    @ViewBuilder
    private func scaffold(for step: OnboardingStep) -> some View {
        OnboardingStepScaffold(
            step: step,
            title: Self.title(for: step),
            subtitle: Self.subtitle(for: step),
            primaryTitle: Self.primaryTitle(for: step),
            // Outcome-gated steps render their primary disabled until
            // the step content records one (moderation's consent, the
            // recovery reveal); `flow.advance()` carries the same
            // guard as the second layer.
            primaryDisabled: flow.requiresOutcomeToAdvance(step) && !flow.outcomeSatisfiesGate(step),
            primaryAction: { primaryTapped() },
            skipTitle: Self.skipTitle(for: step),
            skipAction: flow.isSkippable(step) ? { flow.skip() } : nil,
            // While the directory probe is unresolved, moderation's
            // mandatory state is unknown (failed closed) — show
            // progress where Skip would be instead of nothing.
            showsSkipProgress: step == .moderation && !flow.moderationProbeResolved,
            backAction: step == .welcome ? nil : { flow.back() },
            // Unnumbered steps opt out entirely so the scaffold never
            // reserves a blank indicator band.
            showsIndicator: flow.indicatorPosition(for: step) != nil,
            content: { content(for: step) },
            indicator: {
                if let position = flow.indicatorPosition(for: step) {
                    stepIndicator(position.index, position.count)
                }
            }
        )
    }

    private func primaryTapped() {
        if flow.step == .done {
            flow.complete()
        } else {
            flow.advance()
        }
    }

    /// Injected slot first — the app may override ANY step's body,
    /// Welcome and Done included. nil falls back to the built-ins.
    @ViewBuilder
    private func content(for step: OnboardingStep) -> some View {
        if let injected = stepContent(step) {
            injected
        } else {
            switch step {
            case .welcome:
                WelcomeStepContent()
            case .done:
                DoneStepContent(
                    outcomes: flow.outcomes,
                    recoveryBackupState: flow.recoveryBackupState
                )
            default:
                PlaceholderStepContent(step: step)
            }
        }
    }

    // MARK: - Copy

    static func title(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return String(localized: "Onym")
        case .identity: return String(localized: "Making your keys")
        case .services: return String(localized: "Your services")
        case .moderation: return String(localized: "Reports & safety")
        case .recoveryPhrase: return String(localized: "Save your recovery phrase")
        case .done: return String(localized: "You're ready")
        }
    }

    static func subtitle(for step: OnboardingStep) -> String? {
        switch step {
        case .welcome:
            return String(localized: "Messaging that answers to you — not to a company.")
        case .identity:
            return String(localized: "This takes a second, and it happens only on this iPhone. Nothing is sent anywhere — there's nowhere to send it to yet.")
        case .services:
            return String(localized: "No homeserver to pick. Just independent services for delivery, files and timestamps — split up on purpose, so no single one holds the whole picture.")
        case .moderation:
            return String(localized: "If someone reports illegal content, an authority you choose reviews the report. Pick one to continue — you'll see exactly what it can do before you agree.")
        case .recoveryPhrase:
            return String(localized: "These 12 words ARE your identity. Lose this iPhone without them, and even Onym can't get you back in.")
        case .done:
            return String(localized: "Your identity lives on this device. No account, no admin, no company holds it but you.")
        }
    }

    static func primaryTitle(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return String(localized: "Create my identity")
        case .recoveryPhrase: return String(localized: "I've written it down")
        case .done: return String(localized: "Start messaging")
        default: return String(localized: "Continue")
        }
    }

    /// The skip affordance's label — only the recovery step has one,
    /// and it reads as a deferral, not a skip.
    static func skipTitle(for step: OnboardingStep) -> String {
        switch step {
        case .recoveryPhrase: return String(localized: "Remind me tonight")
        default: return String(localized: "Skip")
        }
    }
}

// MARK: - Built-in step content

/// Welcome step body: brand framing. The app layer replaces this via
/// `stepContent` with the OnymMark-branded version; the built-in
/// keeps the package standalone.
struct WelcomeStepContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            bullet(symbol: "lock.fill",
                   text: "Your identity key is made on this device and stays here.")
            bullet(symbol: "antenna.radiowaves.left.and.right",
                   text: "You pick who carries your messages — and can swap them any time.")
            bullet(symbol: "shield.fill",
                   text: "You pick who handles reports, and see exactly what they can do.")
        }
    }

    private func bullet(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Done step body: summary of what was decided, plus a reminder that
/// everything stays editable in Settings.
struct DoneStepContent: View {
    let outcomes: [OnboardingStep: StepOutcome]
    let recoveryBackupState: RecoveryBackupState

    private static let summarySteps: [OnboardingStep] = [
        .services, .moderation, .recoveryPhrase,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.summarySteps, id: \.self) { step in
                HStack(spacing: 10) {
                    Image(systemName: symbol(for: outcomes[step]))
                        .foregroundStyle(.secondary)
                    Text(verbatim: OnboardingView.title(for: step))
                        .font(.callout)
                    Spacer()
                    Text(verbatim: label(for: step))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Divider()
            Text("Tap any line to change it later in Settings. Nothing here is permanent except your recovery phrase.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func symbol(for outcome: StepOutcome?) -> String {
        switch outcome {
        case .consented: return "checkmark.circle.fill"
        case .skipped: return "arrow.right.circle"
        case .unavailable: return "minus.circle"
        case .notApplicable, nil: return "circle.dashed"
        }
    }

    private func label(for step: OnboardingStep) -> String {
        // The recovery row reports how far the backup ACTUALLY got —
        // "saw the words" and "verified them" both record the same
        // consent outcome, so the outcome alone can't tell them apart.
        if step == .recoveryPhrase {
            switch recoveryBackupState {
            case .verified: return String(localized: "Backed up")
            case .revealed: return String(localized: "Revealed")
            case .none: return String(localized: "Later")
            }
        }
        switch outcomes[step] {
        case .consented: return String(localized: "Chosen")
        case .unavailable: return String(localized: "Unavailable")
        // `.skipped` folds into the default: only recoveryPhrase is
        // skippable, and it is special-cased above — this arm exists
        // for exhaustiveness, not as live logic.
        case .skipped, .notApplicable, nil: return String(localized: "Default")
        }
    }
}

/// Placeholder body for the middle steps when the app doesn't inject
/// real surfaces through `stepContent` (package previews and tests).
struct PlaceholderStepContent: View {
    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(verbatim: OnboardingView.title(for: step))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

/// Fallback step indicator: plain dots. The app replaces it with
/// `SettingsStepIndicator` via the `stepIndicator` slot.
struct DefaultStepIndicator: View {
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { dot in
                Circle()
                    .fill(dot == index ? Color.accentColor : Color(.systemFill))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(index + 1) of \(count)"))
    }
}
