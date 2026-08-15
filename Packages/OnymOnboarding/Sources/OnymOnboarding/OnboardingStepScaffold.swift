import SwiftUI

/// One onboarding step screen, per the established consent-view
/// skeleton: ScrollView + large title + content slot + primary button
/// + text Back/Skip, with the step indicator injected as a view
/// builder slot.
///
/// Deliberately styled with plain SwiftUI — this package does not
/// depend on OnymDesign. PR 3 supplies `SettingsStepIndicator` (made
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

    public init(
        step: OnboardingStep,
        title: String,
        subtitle: String? = nil,
        primaryTitle: String,
        primaryDisabled: Bool = false,
        primaryAction: @escaping () -> Void,
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

                // Secondary actions stack centered under the primary
                // (the design's quiet text buttons) — a corner-pinned
                // Back read as page chrome, not as this screen's
                // alternative action.
                if let skipAction {
                    Button(action: skipAction) { Text(verbatim: skipTitle) }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.\(step.rawValue).skip")
                } else if showsSkipProgress {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.\(step.rawValue).skip_pending")
                }
                if let backAction {
                    Button("Back", action: backAction)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding.\(step.rawValue).back")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }
}
