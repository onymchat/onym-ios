import SwiftUI
import OnymDesign
import OnymModeration

/// Blocking screen for `gateCheckRequired`: the app has no
/// trustworthy gate answer (offline past the grace window, token
/// repeatedly invalid, no attestation path) and the profile fails
/// toward requiring one — never toward unmoderated operation.
public struct GateCheckRequiredView: View {
    let reason: CheckRequiredReason
    let onRetry: () -> Void

    public init(reason: CheckRequiredReason, onRetry: @escaping () -> Void) {
        self.reason = reason
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(.system(size: 40))
                .foregroundStyle(OnymTokens.text2)
            Text("Verification required")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
            SettingsPrimaryButton(action: onRetry) {
                Text("Try again")
            }
            .padding(.horizontal, 48)
            .padding(.top, 8)
            .accessibilityIdentifier("moderation.gate_required.retry")
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnymTokens.surface.ignoresSafeArea())
        .accessibilityIdentifier("moderation.gate_required")
    }

    private var message: String {
        switch reason {
        case .offlineGraceExpired:
            return String(localized: "Onym couldn't verify this device for several days. Connect to the internet to continue.")
        case .neverChecked:
            return String(localized: "Onym needs to verify this device once before it can start. Connect to the internet to continue.")
        case .tokenInvalid:
            return String(localized: "This device's verification token was rejected. Try again.")
        case .attestationUnavailable:
            return String(localized: "Device verification isn't available in this environment.")
        case .reidentificationRequired:
            return String(localized: "This device needs to be re-identified. Sign in with your identity to continue.")
        case .clockRollback:
            return String(localized: "This device's clock is set earlier than its last verification. Check the date and time, then connect to continue.")
        case .backendRefused:
            return String(localized: "The verification service refused this device's session. Try again; if it persists, re-consent to your moderation authority.")
        }
    }
}
