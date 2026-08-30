import SwiftUI

/// One onboarding step screen, per the established consent-view
/// skeleton: ScrollView + large title + content slot + primary button
/// + text Back/Skip, with the step indicator injected as a view
/// builder slot.
///
/// Deliberately styled with plain SwiftUI — this package does not
/// depend on OnymDesign. PR 3 supplies `StepIndicator` (made
/// public there) through the `indicator` slot and can restyle the
/// buttons via the content it injects; the scaffold's own chrome stays
/// system-styled.
///
/// Accessibility identifiers follow `onboarding.<step>.<element>`:
/// `onboarding.<step>.primary`, `onboarding.<step>.skip`,
/// `onboarding.<step>.back`, `onboarding.<step>.title`.
public struct OnboardingStepScaffold<Content: View, Indicator: View>: View {
    private let step: OnboardingStep
    private let title: String
    private let subtitle: String?
    private let primaryTitle: String
    /// Disables the primary button — mandatory steps with no recorded
    /// outcome render Continue disabled (the flow's `advance()` guard
    /// is the second layer of the same rule).
    private let primaryDisabled: Bool
    private let primaryAction: () -> Void
    /// A step's alternative action, rendered as its own button
    /// directly under the primary — the welcome step's "I have a
    /// recovery phrase". Type-erased rather than a third generic
    /// parameter so every existing call site keeps its two trailing
    /// closures. nil for the steps that offer no alternative.
    private let secondaryAction: AnyView?
    /// Label for the Skip affordance — the recovery step reads
    /// "Remind me later"; the default is "Skip".
    private let skipTitle: String
    /// nil hides the Skip affordance (unskippable steps).
    private let skipAction: (() -> Void)?
    /// Renders a small progress indicator in the Skip slot — used
    /// while the flow's moderation-directory probe is unresolved and
    /// skippability is not yet known.
    private let showsSkipProgress: Bool
    /// nil hides the Back affordance (the first step).
    private let backAction: (() -> Void)?
    /// False drops the indicator slot entirely — the unnumbered steps
    /// (welcome, recovery, done) must not carry a blank 24pt band
    /// where the indicator would sit.
    private let showsIndicator: Bool
    private let content: Content
    private let indicator: Indicator
    @Environment(\.colorScheme) private var colorScheme

    public init(
        step: OnboardingStep,
        title: String,
        subtitle: String? = nil,
        primaryTitle: String,
        primaryDisabled: Bool = false,
        primaryAction: @escaping () -> Void,
        secondaryAction: AnyView? = nil,
        skipTitle: String = String(localized: "Skip"),
        skipAction: (() -> Void)? = nil,
        showsSkipProgress: Bool = false,
        backAction: (() -> Void)? = nil,
        showsIndicator: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder indicator: () -> Indicator
    ) {
        self.step = step
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.skipTitle = skipTitle
        self.skipAction = skipAction
        self.showsSkipProgress = showsSkipProgress
        self.backAction = backAction
        self.showsIndicator = showsIndicator
        self.content = content()
        self.indicator = indicator()
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showsIndicator {
                        indicator
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }

                    Text(verbatim: title)
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("onboarding.\(step.rawValue).title")
                        .padding(.top, showsIndicator ? 8 : 24)

                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    content
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                Button(action: primaryAction) {
                    Text(verbatim: primaryTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)
                .accessibilityIdentifier("onboarding.\(step.rawValue).primary")

                // A real alternative to the primary sits with it, in
                // the button stack — not in the scrolling body, where
                // on a wide iPad it lands under a short page of
                // content and reads as part of the last card.
                if let secondaryAction {
                    secondaryAction
                }

                // The remaining actions stack under the primary, in
                // the same secondary look — a corner-pinned Back read
                // as page chrome, not as this screen's alternative
                // action, and a plain text Skip beneath two real
                // buttons read as a footnote to them.
                if let skipAction {
                    Button(action: skipAction) {
                        Text(verbatim: skipTitle).onboardingSecondaryLabel()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding.\(step.rawValue).skip")
                } else if showsSkipProgress {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.\(step.rawValue).skip_pending")
                }
                if let backAction {
                    Button(action: backAction) {
                        Text("Back").onboardingSecondaryLabel()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding.\(step.rawValue).back")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            // The footer is opaque, and casts a soft shadow upward so
            // the body reads as scrolling *under* it rather than
            // stopping short of it. Drawn as a rectangle behind the
            // stack (not a shadow on the stack itself, which would
            // outline each button), offset up so the visible edge is
            // the top one; what spills downward lands on the screen's
            // bottom edge, past everything.
            .background {
                Rectangle()
                    .fill(.background)
                    .shadow(color: footerShadow, radius: 5, y: -2)
                    // Run the rectangle to the screen's bottom edge, so
                    // the shadow it also casts downward falls off the
                    // screen instead of banding across the home-indicator
                    // strip below the buttons.
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    /// The footer's separating shadow. A dark shadow does nothing on a
    /// dark page — the footer's fill and the body behind it are both
    /// near-black — so the edge is lifted with light there instead,
    /// which is the only direction that reads.
    private var footerShadow: Color {
        colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10)
    }
}

/// The footer's secondary look: a button at the primary's metrics,
/// carrying its weight through the border rather than a fill. Public
/// so an app-supplied secondary action (the welcome step's "I have a
/// recovery phrase") matches the ones the scaffold draws itself —
/// apply it to the label and pair it with `.buttonStyle(.bordered)`.
public struct OnboardingSecondaryLabel: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

extension View {
    public func onboardingSecondaryLabel() -> some View {
        modifier(OnboardingSecondaryLabel())
    }
}
