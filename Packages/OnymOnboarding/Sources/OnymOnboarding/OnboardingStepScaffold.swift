import SwiftUI

/// One onboarding step screen, textless: a large step symbol in place
/// of the title, the content slot, and a footer of icon-only buttons
/// (Back, Skip, primary). Every string the scaffold is given is an
/// accessibility label — VoiceOver reads it, the screen never shows
/// it. The step indicator is injected as a view builder slot.
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
    /// Accessibility label for `symbol`; carries the
    /// `onboarding.<step>.title` identifier the UI tests anchor on.
    private let title: String
    private let symbol: String
    /// VoiceOver hint on the symbol — what the step's subtitle said.
    private let hint: String?
    private let primaryTitle: String
    private let primarySymbol: String
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
    private let skipSymbol: String
    /// nil hides the Skip affordance (unskippable steps).
    private let skipAction: (() -> Void)?
    /// Renders a small progress indicator in the Skip slot — used
    /// while the flow's moderation-directory probe is unresolved and
    /// skippability is not yet known.
    private let showsSkipProgress: Bool
    /// nil hides the Back affordance (the first step).
    private let backAction: (() -> Void)?
    /// Leave onboarding entirely — an icon button pinned top-trailing,
    /// apart from the footer's per-step actions. nil hides it (Done,
    /// whose primary already finishes).
    private let skipAllAction: (() -> Void)?
    /// False drops the indicator slot entirely — the unnumbered steps
    /// (welcome, recovery, done) must not carry a blank 24pt band
    /// where the indicator would sit.
    private let showsIndicator: Bool
    /// Centre the symbol and content, as one group, in the space above
    /// the footer — for steps short enough to have nothing to scroll.
    private let centersContent: Bool
    /// False when the content IS the symbol (identity: the key, badged
    /// with its status) — the scaffold then draws none of its own.
    private let showsSymbol: Bool
    private let content: Content
    private let indicator: Indicator
    @Environment(\.colorScheme) private var colorScheme

    public init(
        step: OnboardingStep,
        title: String,
        symbol: String,
        hint: String? = nil,
        primaryTitle: String,
        primarySymbol: String = "arrow.right",
        primaryDisabled: Bool = false,
        primaryAction: @escaping () -> Void,
        secondaryAction: AnyView? = nil,
        skipTitle: String = String(localized: "Skip"),
        skipSymbol: String = "forward",
        skipAction: (() -> Void)? = nil,
        showsSkipProgress: Bool = false,
        backAction: (() -> Void)? = nil,
        skipAllAction: (() -> Void)? = nil,
        showsIndicator: Bool = true,
        centersContent: Bool = false,
        showsSymbol: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder indicator: () -> Indicator
    ) {
        self.step = step
        self.title = title
        self.symbol = symbol
        self.hint = hint
        self.primaryTitle = primaryTitle
        self.primarySymbol = primarySymbol
        self.primaryDisabled = primaryDisabled
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.skipTitle = skipTitle
        self.skipSymbol = skipSymbol
        self.skipAction = skipAction
        self.showsSkipProgress = showsSkipProgress
        self.backAction = backAction
        self.skipAllAction = skipAllAction
        self.showsIndicator = showsIndicator
        self.centersContent = centersContent
        self.showsSymbol = showsSymbol
        self.content = content()
        self.indicator = indicator()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                if centersContent {
                    centeredBody
                } else {
                    scrollingBody
                }
            }
            // Top bar, mirrored: Back on the left, leave-setup on the
            // right — the same two round icons at the same height.
            .overlay(alignment: .topLeading) {
                if let backAction {
                    cornerIcon("arrow.left", label: String(localized: "Back"), action: backAction)
                        .accessibilityIdentifier("onboarding.\(step.rawValue).back")
                }
            }
            .overlay(alignment: .topTrailing) {
                if let skipAllAction {
                    cornerIcon("door.left.hand.open", label: String(localized: "Skip setup"), action: skipAllAction)
                        .accessibilityIdentifier("onboarding.\(step.rawValue).skip_all")
                }
            }

            // Footer: the step's answers, side by side at equal width —
            // a deferral (Skip) is a full button beside the primary,
            // never a small icon a user has to hunt for. Without one,
            // the primary takes the whole row.
            VStack(spacing: 12) {
                if let secondaryAction {
                    secondaryAction
                }

                HStack(spacing: 12) {
                    if let skipAction {
                        Button(action: skipAction) {
                            Image(systemName: skipSymbol)
                                .font(.system(size: 22, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel(Text(verbatim: skipTitle))
                        .accessibilityIdentifier("onboarding.\(step.rawValue).skip")
                    } else if showsSkipProgress {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .accessibilityIdentifier("onboarding.\(step.rawValue).skip_pending")
                    }

                    Button(action: primaryAction) {
                        Image(systemName: primarySymbol)
                            .font(.system(size: 22, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(primaryDisabled)
                    .accessibilityLabel(Text(verbatim: primaryTitle))
                    .accessibilityIdentifier("onboarding.\(step.rawValue).primary")
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

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showsIndicator {
                    indicator
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }

                stepSymbol
                    .padding(.top, showsIndicator ? 8 : 24)

                content
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    /// Content centred in the whole area above the footer — the
    /// indicator rides on top as an overlay so it can't push the
    /// content off centre. Still scrolls if the screen is too short.
    private var centeredBody: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    if showsSymbol {
                        stepSymbol
                        content
                    } else {
                        content
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(Text(verbatim: title))
                            .accessibilityHint(Text(verbatim: hint ?? ""))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("onboarding.\(step.rawValue).title")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .padding(.horizontal, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .overlay(alignment: .top) {
            if showsIndicator {
                indicator.padding(.top, 24)
            }
        }
    }

    private var stepSymbol: some View {
        Image(systemName: symbol)
            .font(.system(size: 56, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityHint(Text(verbatim: hint ?? ""))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("onboarding.\(step.rawValue).title")
    }

    private func cornerIcon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .accessibilityLabel(Text(verbatim: label))
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
