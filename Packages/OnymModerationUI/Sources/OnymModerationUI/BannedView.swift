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
                        .font(OnymType.font(size: 40))
                        .foregroundStyle(OnymTokens.red)
                    Text("This device is banned from Onym")
                        .font(OnymType.font(size: 20, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                        .multilineTextAlignment(.center)
                    Text(expiryLine)
                        .font(OnymType.font(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                // Keep the primary escape hatch in the first viewport. The
                // verdict details can be long, but a banned user must not
                // have to discover the appeal action by scrolling.
                if let builder = caseFlowBuilder {
                    SettingsPrimaryButton(action: { caseSheet = .appeal }) {
                        Text("Review case and appeal")
                    }
                    .accessibilityIdentifier("moderation.banned.appeal")
                    .padding(.horizontal, 16)
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
                    .padding(.horizontal, 16)
                }

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
                    // In-app appeal is primary — the flow retains the
                    // exact signed filing and its receipt. The external
                    // appellate link SUPPLEMENTS it rather than being
                    // replaced: the case screen can be unable to help
                    // (mandate no longer retained, authority missing
                    // from the directory, anti-oracle 404), and a
                    // permanent ban's header explicitly promises the
                    // external appellate remains available.
                    if caseFlowBuilder != nil {
                        if let appealURL = state.appealURL {
                            Button {
                                openURL(appealURL)
                            } label: {
                                Text("Appeal at the authority's appellate")
                                    .font(OnymType.font(size: 15, weight: .medium))
                                    .foregroundStyle(OnymTokens.text)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(OnymTokens.surface2,
                                                in: RoundedRectangle(cornerRadius: OnymRadius.inset, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("moderation.banned.appeal_external")
                        }
                    }
                    // The new-holder path is its own affordance, not a
                    // footnote: DeviceCheck bits survive resale, and the
                    // device's next owner is the person this screen is
                    // most likely wronging. Shown only when it actually
                    // leads somewhere; otherwise the footnote below
                    // routes them to the authority directly.
                    if hasNewHolderPath {
                        Button {
                            // In-app first, matching the appeal button:
                            // the flow retains the exact signed filing
                            // and its receipt, which a link-out cannot.
                            if caseFlowBuilder != nil {
                                // The case sheet carries the
                                // new-holder section (banContext);
                                // open it scrolled to that section.
                                caseSheet = .newHolder
                            } else if let url = state.newHolderURL {
                                openURL(url)
                            } else {
                                onNewHolderClaim?()
                            }
                        } label: {
                            Text("I'm this device's new owner")
                                .font(OnymType.font(size: 15, weight: .medium))
                                .foregroundStyle(OnymTokens.text)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(OnymTokens.surface2,
                                            in: RoundedRectangle(cornerRadius: OnymRadius.inset, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("moderation.banned.new_holder")
                        // The authority's own procedure SUPPLEMENTS the
                        // in-app claim, exactly like the appeal path:
                        // the canonical new holder has a fresh install,
                        // so the in-app filing (which signs with a
                        // retained mandate context) can dead-end with
                        // "mandate no longer on this device" — a
                        // working authority URL must never be hidden
                        // behind a form that cannot succeed for them.
                        if caseFlowBuilder != nil, let url = state.newHolderURL {
                            Button {
                                openURL(url)
                            } label: {
                                Text("File the claim at the authority instead")
                                    .font(OnymType.font(size: 13))
                                    .foregroundStyle(OnymTokens.text2)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("moderation.banned.new_holder_external")
                        }
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
                .font(OnymType.font(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(value)
                .font(monospaced ? OnymType.mono(size: 12) : OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .textSelection(.enabled)
        }
    }
}
