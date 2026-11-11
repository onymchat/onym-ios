import SwiftUI
import OnymDesignTokens

/// The first-launch onboarding cover: one scaffolded screen per
/// `OnboardingStep`, driven by `OnboardingFlow`.
///
/// Presentation contract: RootView presents this as a
/// `fullScreenCover` with `.interactiveDismissDisabled(true)` applied
/// at the presentation site — a full-screen cover has no interactive
/// dismissal of its own, but the modifier documents intent and guards
/// against a future switch to `.sheet`. The only exits are
/// `flow.complete()` on the Done step and `flow.skipAll()` — the
/// welcome screen's main button, or the skip-setup icon on the steps
/// after it; onboarding is never swiped away half-done.
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
    /// App-supplied alternative action for a step, rendered in the
    /// scaffold's button stack under the primary rather than inside
    /// the scrolling body. Return nil for steps that have none — which
    /// is every step but Welcome today.
    private let stepSecondaryAction: (OnboardingStep) -> AnyView?
    /// App-supplied step indicator, given (zero-based index, count).
    /// Only rendered on the steps the indicator counts — the three
    /// core steps; welcome, recoveryPhrase and done are unnumbered.
    private let stepIndicator: (Int, Int) -> AnyView

    public init(
        flow: OnboardingFlow,
        stepContent: ((OnboardingStep) -> AnyView?)? = nil,
        stepSecondaryAction: ((OnboardingStep) -> AnyView?)? = nil,
        stepIndicator: ((Int, Int) -> AnyView)? = nil
    ) {
        _flow = State(initialValue: flow)
        self.stepContent = stepContent ?? { _ in nil }
        self.stepSecondaryAction = stepSecondaryAction ?? { _ in nil }
        self.stepIndicator = stepIndicator ?? { index, count in
            AnyView(DefaultStepIndicator(index: index, count: count))
        }
    }

    public var body: some View {
        Group {
            if flow.step == .welcome {
                welcomeScreen
            } else {
                scaffold(for: flow.step)
            }
        }
        .task { flow.start() }
    }

    // MARK: - Welcome

    /// No text: the mark, one dominant button that skips straight to
    /// Chats, and a bottom row of icon-only alternatives — set up step
    /// by step, and (app-supplied) restore from a recovery phrase.
    /// Every button carries an accessibility label in place of a title.
    private var welcomeScreen: some View {
        // The door sits dead centre of the screen; the bottom row is an
        // overlay so its height can't push it off.
        Button { flow.skipAll() } label: {
            Image(systemName: "door.left.hand.open")
                .font(OnymType.fixed(size: 34, weight: .semibold))
                .frame(width: 104, height: 104)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text(verbatim: Self.primaryTitle(for: .welcome)))
        .accessibilityIdentifier("onboarding.welcome.primary")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            HStack(spacing: 24) {
                Button { flow.advance() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(OnymType.fixed(size: 20, weight: .semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("Set up step by step"))
                .accessibilityIdentifier("onboarding.welcome.setup")

                if let restore = stepSecondaryAction(.welcome) {
                    restore
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 20)
        // No title on screen any more; the container carries the
        // anchor the UI tests wait on.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Self.title(for: .welcome)))
        .accessibilityIdentifier("onboarding.welcome.title")
    }

    // MARK: - Steps

    @ViewBuilder
    private func scaffold(for step: OnboardingStep) -> some View {
        OnboardingStepScaffold(
            step: step,
            title: Self.title(for: step, restoring: flow.identityOrigin == .restored),
            symbol: Self.symbol(for: step),
            hint: Self.subtitle(for: step, restoring: flow.identityOrigin == .restored),
            primaryTitle: Self.primaryTitle(for: step),
            // A mandatory moderation step finishes by signing, so its
            // primary is the signature rather than an arrow.
            primarySymbol: step == .moderation && flow.isMandatory(step)
                ? "signature"
                : Self.primarySymbol(for: step),
            // Outcome-gated steps render their primary disabled until
            // the step content records one (moderation's consent, the
            // recovery reveal); `flow.advance()` carries the same
            // guard as the second layer.
            primaryDisabled: flow.requiresOutcomeToAdvance(step)
                && !flow.outcomeSatisfiesGate(step)
                && flow.primaryOverride == nil,
            primaryAction: { primaryTapped() },
            secondaryAction: stepSecondaryAction(step),
            skipTitle: Self.skipTitle(for: step),
            // An alarm clock: "remind me later", not "skip for good".
            skipSymbol: step == .recoveryPhrase ? "alarm" : "forward",
            skipAction: flow.isSkippable(step) ? { flow.skip() } : nil,
            // While the directory probe is unresolved, moderation's
            // mandatory state is unknown (failed closed) — show
            // progress where Skip would be instead of nothing.
            showsSkipProgress: step == .moderation && !flow.moderationProbeResolved,
            backAction: step == .welcome ? nil : { flow.back() },
            // Mid-walk way out for whoever opted in to the steps.
            // Done's primary already finishes.
            skipAllAction: step == .done ? nil : { flow.skipAll() },
            // Unnumbered steps opt out entirely so the scaffold never
            // reserves a blank indicator band.
            showsIndicator: flow.indicatorPosition(for: step) != nil,
            // Short steps sit centred. Identity's content is its key,
            // badged with the bootstrap's state, in place of the symbol.
            centersContent: step == .identity || step == .services
                || step == .moderation || step == .recoveryPhrase || step == .done,
            // Identity's key and recovery's life preserver are the
            // content itself, each badged with its state.
            showsSymbol: step != .identity && step != .recoveryPhrase,
            content: { content(for: step) },
            indicator: {
                if let position = flow.indicatorPosition(for: step) {
                    stepIndicator(position.index, position.count)
                }
            }
        )
    }

    private func primaryTapped() {
        if let override = flow.primaryOverride, !flow.outcomeSatisfiesGate(flow.step) {
            override()
        } else if flow.step == .done {
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

    static func title(for step: OnboardingStep, restoring: Bool = false) -> String {
        switch step {
        case .welcome: return String(localized: "Onym")
        case .identity:
            return restoring
                ? String(localized: "Restoring your identity")
                : String(localized: "Making your keys")
        case .services: return String(localized: "Your services")
        case .moderation: return String(localized: "Reports & safety")
        case .recoveryPhrase: return String(localized: "Save your recovery phrase")
        case .done: return String(localized: "You're ready")
        }
    }

    /// What stands on screen in place of each step's title.
    static func symbol(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "key.horizontal"
        case .identity: return "key.horizontal.fill"
        case .services: return "server.rack"
        case .moderation: return "shield.lefthalf.filled"
        case .recoveryPhrase: return "lifepreserver.fill"
        case .done: return "checkmark.seal.fill"
        }
    }

    static func primarySymbol(for step: OnboardingStep) -> String {
        switch step {
        case .recoveryPhrase: return "checkmark"
        case .done: return "door.left.hand.open"
        default: return "arrow.right"
        }
    }

    /// Spoken by VoiceOver as each step's header hint — never shown.
    static func subtitle(for step: OnboardingStep, restoring: Bool = false) -> String? {
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
            // Word count varies (12 or 24) for a restored phrase, and a
            // restored phrase is the one the user just typed in — not
            // new information the step is revealing to them for the
            // first time.
            return restoring
                ? String(localized: "This is the phrase you just entered. Lose this iPhone without a copy of it, and even Onym can't get you back in.")
                : String(localized: "These 12 words ARE your identity. Lose this iPhone without them, and even Onym can't get you back in.")
        case .done:
            return String(localized: "Your identity lives on this device. No account, no admin, no company holds it but you.")
        }
    }

    static func primaryTitle(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return String(localized: "Start messaging")
        case .recoveryPhrase: return String(localized: "I've written it down")
        case .done: return String(localized: "Start messaging")
        default: return String(localized: "Continue")
        }
    }

    /// The skip affordance's label — only the recovery step has one,
    /// and it reads as a deferral, not a skip.
    static func skipTitle(for step: OnboardingStep) -> String {
        switch step {
        case .recoveryPhrase: return String(localized: "Remind me later")
        default: return String(localized: "Skip")
        }
    }
}

// MARK: - Built-in step content

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
            RoundedRectangle(cornerRadius: OnymRadius.inset)
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
                .font(OnymType.font(size: 28))
                .foregroundStyle(.secondary)
            Text(verbatim: OnboardingView.title(for: step))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: OnymRadius.inset)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

/// Fallback step indicator: plain dots. The app replaces it with
/// `StepIndicator` via the `stepIndicator` slot.
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
