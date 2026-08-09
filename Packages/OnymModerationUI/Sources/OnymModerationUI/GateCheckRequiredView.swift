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
    let makeRecoveryCaseFlow: (@MainActor (String) async -> ModerationCaseFlow?)?

    @State private var showRecovery = false

    public init(
        reason: CheckRequiredReason,
        onRetry: @escaping () -> Void,
        makeRecoveryCaseFlow: (@MainActor (String) async -> ModerationCaseFlow?)? = nil
    ) {
        self.reason = reason
        self.onRetry = onRetry
        self.makeRecoveryCaseFlow = makeRecoveryCaseFlow
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
            if reason == .reidentificationRequired, makeRecoveryCaseFlow != nil {
                Button("Appeal by case ID") { showRecovery = true }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OnymTokens.text)
                    .accessibilityIdentifier("moderation.gate_required.appeal")
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnymTokens.surface.ignoresSafeArea())
        .accessibilityIdentifier("moderation.gate_required")
        .sheet(isPresented: $showRecovery) {
            if let makeRecoveryCaseFlow {
                RecoveryAppealView(makeCaseFlow: makeRecoveryCaseFlow)
            }
        }
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
            return String(localized: "The verification service refused this device's session. Check the date and time, then try again.")
        case .enrollmentLost:
            // Normally unreachable: the gate flow routes this state to
            // consent. Rendered when the authorities directory is
            // unavailable (so the consent flow has nothing to offer)
            // or if a host wires the view directly.
            return String(localized: "This device's enrollment is no longer on record. Consent to your moderation authority again to re-enroll.")
        }
    }
}

/// Recovery entry point for a reinstall: the user supplies the case ID
/// from the original notice/verdict, then the existing case flow signs the
/// appeal with the identity retained in Keychain and sends it to Authority.
private struct RecoveryAppealView: View {
    let makeCaseFlow: @MainActor (String) async -> ModerationCaseFlow?

    @Environment(\.dismiss) private var dismiss
    @State private var caseID = ""
    @State private var flow: ModerationCaseFlow?
    @State private var errorMessage: String?
    @State private var isOpening = false

    var body: some View {
        NavigationStack {
            Group {
                if let flow {
                    ModerationCaseView(flow: flow, focusNewHolder: false)
                } else {
                    form
                }
            }
            .navigationTitle("Appeal a moderation case")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .disabled(isOpening)
                }
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Share your retained Onym identity with the Authority and open the case appeal form. The Authority verifies the signed appeal against the accused identity; it does not receive your private key.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(3)

                TextField("Case ID", text: $caseID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("moderation.recovery.case_id")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .accessibilityIdentifier("moderation.recovery.error")
                }

                SettingsPrimaryButton(action: openCase) {
                    Text(isOpening ? "Opening…" : "Continue to appeal")
                }
                .disabled(caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isOpening)
                .accessibilityIdentifier("moderation.recovery.continue")
            }
            .padding(20)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
    }

    private func openCase() {
        let caseID = caseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caseID.isEmpty else { return }
        isOpening = true
        errorMessage = nil
        Task { @MainActor in
            if let resolved = await makeCaseFlow(caseID) {
                flow = resolved
            } else {
                errorMessage = "No active moderation identity is available. Consent to the authority again, then retry."
            }
            isOpening = false
        }
    }
}
