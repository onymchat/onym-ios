import SwiftUI

/// The first-launch onboarding cover: one scaffolded screen per
/// `OnboardingStep`, driven by `OnboardingFlow`.
///
/// Presentation contract: RootView (PR 3) presents this as a
/// `fullScreenCover` with `.interactiveDismissDisabled(true)` applied
/// at the presentation site — a full-screen cover has no interactive
/// dismissal of its own, but the modifier documents intent and guards
/// against a future switch to `.sheet`. The only exits are
/// `flow.complete()` on the Done step and the per-step Skip
/// affordances; onboarding is never swiped away half-done.
///
/// Dependency posture: this package renders the *frame* of each step.
/// The middle steps' real content — discovery confirm, catalog
/// pickers, the moderation mandate flow — lives at the app layer and
/// arrives through `stepContent` in PR 3, so this view stays free of
/// OnymDiscovery / OnymModerationUI / OnymDesign. Likewise the step
/// indicator arrives through `stepIndicator` (PR 3 passes
/// `SettingsStepIndicator` once it is public); the default is a plain
/// dot indicator so the package previews and tests stand alone.
public struct OnboardingView: View {
    @State private var flow: OnboardingFlow
    /// App-supplied content slot, consulted for EVERY step (Welcome
    /// and Done included). Return nil to fall back to the built-ins:
    /// the Welcome/Done bodies, and a placeholder card for the middle
    /// steps until PR 3 supplies the real surfaces.
    private let stepContent: (OnboardingStep) -> AnyView?
    /// App-supplied step indicator, given (zero-based index, count).
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
            primaryTitle: step == .done ? String(localized: "Start") : String(localized: "Continue"),
            // Mandatory steps render Continue disabled until the step
            // content records an outcome; `flow.advance()` carries the
            // same guard as the second layer.
            primaryDisabled: flow.isMandatory(step) && flow.outcomes[step] == nil,
            primaryAction: { primaryTapped() },
            skipAction: flow.isSkippable(step) ? { flow.skip() } : nil,
            // While the directory probe is unresolved, moderation's
            // skippability is unknown (failed closed) — show progress
            // where Skip would be instead of nothing.
            showsSkipProgress: step == .moderation && !flow.moderationProbeResolved,
            backAction: step == .welcome ? nil : { flow.back() },
            content: { content(for: step) },
            indicator: { stepIndicator(flow.stepIndex, flow.stepCount) }
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
                DoneStepContent(outcomes: flow.outcomes)
            default:
                PlaceholderStepContent(step: step)
            }
        }
    }

    // MARK: - Copy

    static func title(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return String(localized: "Welcome to Onym")
        case .discoveryConfirm: return String(localized: "Service Directory")
        case .messageTransport: return String(localized: "Message Transport")
        case .blobTransport: return String(localized: "File Storage")
        case .notary: return String(localized: "Notary")
        case .moderation: return String(localized: "Moderation")
        case .done: return String(localized: "You're Set")
        }
    }

    static func subtitle(for step: OnboardingStep) -> String? {
        switch step {
        case .welcome:
            return String(localized: "Your keys, your services. Pick who carries your messages, stores your files, and vouches for your history — every choice is yours, and every one can change later in Settings.")
        case .discoveryConfirm:
            return String(localized: "Confirm the directory your app uses to find services, or add your own provider.")
        case .messageTransport:
            return String(localized: "Choose who relays your messages.")
        case .blobTransport:
            return String(localized: "Choose where your attachments are stored.")
        case .notary:
            return String(localized: "Choose who timestamps your conversation history.")
        case .moderation:
            return String(localized: "Choose a moderation authority and review its terms.")
        case .done:
            return String(localized: "Your choices are saved. You can revisit any of them in Settings.")
        }
    }
}

// MARK: - Built-in step content

/// Welcome step body: brand framing. PR 3 may replace the mark via
/// `stepContent` if richer branding (OnymMark) is wanted; the built-in
/// keeps the package standalone.
struct WelcomeStepContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            Text("The next few screens set up the services this app runs on. Each one shows exactly what you're agreeing to before anything is turned on.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Done step body: summary of what was chosen per step, plus the
/// backup nudge (identity was created silently; the phrase flow lives
/// in Settings and is nudged here, never forced).
struct DoneStepContent: View {
    let outcomes: [OnboardingStep: StepOutcome]

    private static let summarySteps: [OnboardingStep] = [
        .discoveryConfirm, .messageTransport, .blobTransport, .notary, .moderation,
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
                    Text(verbatim: label(for: outcomes[step]))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Divider()
            Text("Your identity key was created on this device. Back it up from Settings so you can recover your account.")
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
        case .notApplicable, nil: return "circle.dashed"
        }
    }

    private func label(for outcome: StepOutcome?) -> String {
        switch outcome {
        case .consented: return String(localized: "Chosen")
        case .skipped: return String(localized: "Default")
        case .notApplicable, nil: return String(localized: "—")
        }
    }
}

/// Placeholder body for the middle steps until PR 3 injects the real
/// surfaces through `stepContent`.
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

/// Fallback step indicator: plain dots. PR 3 replaces it with
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
