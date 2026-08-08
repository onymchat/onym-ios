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
    /// Entry point into the authority's appeal path. Stubbed today
    /// (`ModerationAuthorityClient.appeal` throws `.notImplemented`);
    /// the URLs below remain the declared out-of-band procedure.
    let onNewHolderClaim: () -> Void

    @Environment(\.openURL) private var openURL

    public init(state: BanState, onNewHolderClaim: @escaping () -> Void = {}) {
        self.state = state
        self.onNewHolderClaim = onNewHolderClaim
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
                    if let appealURL = state.appealURL {
                        SettingsPrimaryButton(action: { openURL(appealURL) }) {
                            Text("Appeal this ban")
                        }
                        .accessibilityIdentifier("moderation.banned.appeal")
                    }
                    // The new-holder path is its own affordance, not a
                    // footnote: DeviceCheck bits survive resale, and the
                    // device's next owner is the person this screen is
                    // most likely wronging.
                    Button {
                        if let url = state.newHolderURL {
                            openURL(url)
                        } else {
                            onNewHolderClaim()
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
                .padding(.horizontal, 16)
                .padding(.top, 16)
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
