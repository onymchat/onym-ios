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
    private let primaryAction: () -> Void
    /// nil hides the Skip affordance (unskippable steps).
    private let skipAction: (() -> Void)?
    /// nil hides the Back affordance (the first step).
    private let backAction: (() -> Void)?
    private let content: Content
    private let indicator: Indicator

    public init(
        step: OnboardingStep,
        title: String,
        subtitle: String? = nil,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        skipAction: (() -> Void)? = nil,
        backAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder indicator: () -> Indicator
    ) {
        self.step = step
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.skipAction = skipAction
        self.backAction = backAction
        self.content = content()
        self.indicator = indicator()
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    indicator
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)

                    Text(verbatim: title)
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("onboarding.\(step.rawValue).title")
                        .padding(.top, 8)

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
                .accessibilityIdentifier("onboarding.\(step.rawValue).primary")

                HStack {
                    if let backAction {
                        Button("Back", action: backAction)
                            .accessibilityIdentifier("onboarding.\(step.rawValue).back")
                    }
                    Spacer()
                    if let skipAction {
                        Button("Skip", action: skipAction)
                            .accessibilityIdentifier("onboarding.\(step.rawValue).skip")
                    }
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }
}
