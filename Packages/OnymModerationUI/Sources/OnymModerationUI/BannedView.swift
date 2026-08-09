import SwiftUI
import OnymDesign
import OnymModeration

/// The enforcement UX for a banned device (DeviceCheck profile §5):
/// full-screen, non-dismissable, and complete — verdict reference,
/// violation class, reasoning address, authority contact, expiry, and
/// both appeal paths including the new-holder claim. A silent brick
/// is nonconforming; this screen is the conforming alternative.
public struct BannedView: View {
    let state: BanState
    /// Entry point into the authority's new-holder procedure when the
    /// verdict carries no `newHolderURL`. No default: this is the most
    /// safety-critical affordance on the screen, and an empty closure
    /// would make tapping it do nothing — a dead button on a blocking
    /// screen is the silent brick the profile forbids. Callers with no
    /// in-app path pass `nil`, and the screen falls back to the
    /// authority's contact instead of offering a button that lies.
    let onNewHolderClaim: (() -> Void)?
    /// Builds the in-app case flow for the banning verdict's case.
    /// When present and the verdict is attached, appeal and new-holder
    /// filings happen in-app; URLs (if the authority serves them) and
    /// the contact fallback remain for verdicts without a case path.
    let makeCaseFlow: (@MainActor (_ caseId: String, _ mandateRef: String) -> ModerationCaseFlow)?

    private enum CaseSheet: String, Identifiable {
        case appeal, newHolder
        var id: String { rawValue }
    }

    @Environment(\.openURL) private var openURL
    @State private var caseSheet: CaseSheet?

    public init(
        state: BanState,
        onNewHolderClaim: (() -> Void)? = nil,
        makeCaseFlow: (@MainActor (_ caseId: String, _ mandateRef: String) -> ModerationCaseFlow)? = nil
    ) {
        self.state = state
        self.onNewHolderClaim = onNewHolderClaim
        self.makeCaseFlow = makeCaseFlow
    }

    /// In-app path into the banning case, when the verdict is attached.
    private var caseFlowBuilder: (@MainActor () -> ModerationCaseFlow)? {
        guard let makeCaseFlow, let verdict = state.verdict else { return nil }
        return { makeCaseFlow(verdict.caseId, verdict.mandateRef) }
    }

    /// Whether the new-holder path can actually be reached from here.
    private var hasNewHolderPath: Bool {
        state.newHolderURL != nil || onNewHolderClaim != nil || caseFlowBuilder != nil
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(OnymTokens.red)
                    Text("This device is banned from Onym")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                        .multilineTextAlignment(.center)
                    Text(expiryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                SettingsSectionLabel("VERDICT")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Reference", state.verdictRef, monospaced: true)
                        if let verdict = state.verdict {
                            detailRow("Violation class", verdict.classId)
                            detailRow("Decided", verdict.decidedAt.formatted(date: .abbreviated, time: .shortened))
                            detailRow("Reasoning", verdict.reasoning, monospaced: true)
                            if let appealDeadline = verdict.appealDeadline {
                                detailRow("Appeal deadline", appealDeadline.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        detailRow("Authority contact", state.authorityContact)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                SettingsFootnote("The ban covers this device on this app only. The Onym protocol itself remains open.")

                VStack(spacing: 10) {
                    // In-app appeal outranks a link-out: the flow
                    // retains the exact signed filing and its receipt.
                    if let builder = caseFlowBuilder {
                        SettingsPrimaryButton(action: { caseSheet = .appeal }) {
                            Text("Review case and appeal")
                        }
                        .accessibilityIdentifier("moderation.banned.appeal")
                        .sheet(item: $caseSheet) { sheet in
                            NavigationStack {
                                ModerationCaseView(
                                    flow: builder(),
                                    focusNewHolder: sheet == .newHolder
                                )
                            }
                        }
                    } else if let appealURL = state.appealURL {
                        SettingsPrimaryButton(action: { openURL(appealURL) }) {
                            Text("Appeal this ban")
                        }
                        .accessibilityIdentifier("moderation.banned.appeal")
                    }
                    // The new-holder path is its own affordance, not a
                    // footnote: DeviceCheck bits survive resale, and the
                    // device's next owner is the person this screen is
                    // most likely wronging. Shown only when it actually
                    // leads somewhere; otherwise the footnote below
                    // routes them to the authority directly.
                    if hasNewHolderPath {
                        Button {
                            if let url = state.newHolderURL {
                                openURL(url)
                            } else if caseFlowBuilder != nil {
                                // The case sheet carries the
                                // new-holder section (banContext);
                                // open it scrolled to that section.
                                caseSheet = .newHolder
                            } else {
                                onNewHolderClaim?()
                            }
                        } label: {
                            Text("I'm this device's new owner")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(OnymTokens.text)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(OnymTokens.surface2,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("moderation.banned.new_holder")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                if !hasNewHolderPath {
                    SettingsFootnote("If you're this device's new owner, contact the authority above — device bans survive a change of hands, and the authority runs an expedited procedure for it.")
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .accessibilityIdentifier("moderation.banned")
    }

    private var expiryLine: String {
        if let expiry = state.banExpires {
            return String(localized: "Until \(expiry.formatted(date: .long, time: .omitted)). You can appeal below.")
        }
        return String(localized: "Permanent. It remains appealable at the authority's external appellate for as long as it is in force.")
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }
}
