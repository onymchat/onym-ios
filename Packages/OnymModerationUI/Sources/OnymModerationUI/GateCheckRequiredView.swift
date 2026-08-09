import SwiftUI
import OnymDesign
import OnymModeration

/// Blocking screen for `gateCheckRequired`: the app has no
/// trustworthy gate answer (offline past the grace window, token
/// repeatedly invalid, no attestation path) and the profile fails
/// toward requiring one — never toward unmoderated operation.
public struct GateCheckRequiredView: View {
    let reason: CheckRequiredReason
    let onRetry: @MainActor () async -> Void
    let lookupRecoveryCaseIDs: (@MainActor () async -> [String])?
    let makeRecoveryCaseFlow: (@MainActor (String) async -> ModerationCaseFlow?)?

    @State private var showRecovery = false
    @State private var isRetrying = false
    @State private var retryMessage: String?

    public init(
        reason: CheckRequiredReason,
        onRetry: @escaping @MainActor () async -> Void,
        lookupRecoveryCaseIDs: (@MainActor () async -> [String])? = nil,
        makeRecoveryCaseFlow: (@MainActor (String) async -> ModerationCaseFlow?)? = nil
    ) {
        self.reason = reason
        self.onRetry = onRetry
        self.lookupRecoveryCaseIDs = lookupRecoveryCaseIDs
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
            if canRetry {
                SettingsPrimaryButton(action: retry) {
                    if isRetrying {
                        ProgressView().tint(OnymTokens.onAccent)
                    } else {
                        Text("Retry verification")
                    }
                }
                .disabled(isRetrying)
                .padding(.horizontal, 48)
                .padding(.top, 8)
                .accessibilityIdentifier("moderation.gate_required.retry")
            }
            if let retryMessage {
                Text(retryMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("moderation.gate_required.retry_result")
            }
            if reason == .reidentificationRequired,
               lookupRecoveryCaseIDs != nil,
               makeRecoveryCaseFlow != nil {
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
            if let lookupRecoveryCaseIDs, let makeRecoveryCaseFlow {
                RecoveryAppealView(
                    lookupCaseIDs: lookupRecoveryCaseIDs,
                    makeCaseFlow: makeRecoveryCaseFlow
                )
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
            return String(localized: "Apple rejected this device's verification token. Retry requests a fresh token; if it keeps failing, the app build and moderation service may be using different DeviceCheck environments.")
        case .attestationUnavailable:
            return String(localized: "Device verification isn't available in this environment. This is expected on Simulator; use UI-testing mode or a physical device.")
        case .reidentificationRequired:
            return String(localized: "This install has a DeviceCheck mark, but it cannot be safely attached to the retained identity. Retrying cannot change that; recover the case below and appeal it.")
        case .clockRollback:
            return String(localized: "This device's clock is set earlier than its last verification. Check the date and time, then connect to continue.")
        case .backendRefused:
            return String(localized: "The verification service refused this signed session. Check the date, time, and network connection, then retry to create a fresh session.")
        case .enrollmentLost:
            // Normally unreachable: the gate flow routes this state to
            // consent. Rendered when the authorities directory is
            // unavailable (so the consent flow has nothing to offer)
            // or if a host wires the view directly.
            return String(localized: "This device's enrollment is no longer on record. Consent to your moderation authority again to re-enroll.")
        }
    }

    private var canRetry: Bool {
        switch reason {
        case .offlineGraceExpired, .neverChecked, .tokenInvalid, .clockRollback, .backendRefused:
            return true
        case .attestationUnavailable, .reidentificationRequired, .enrollmentLost:
            return false
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        retryMessage = nil
        Task { @MainActor in
            await onRetry()
            isRetrying = false
            retryMessage = String(localized: "The verification attempt finished, but this screen did not change. The explanation above describes what this state requires.")
        }
    }
}

/// Recovery entry point for a reinstall: the user supplies the case ID
/// from the original notice/verdict, then the existing case flow signs the
/// appeal with the identity retained in Keychain and sends it to Authority.
private struct RecoveryAppealView: View {
    let lookupCaseIDs: @MainActor () async -> [String]
    let makeCaseFlow: @MainActor (String) async -> ModerationCaseFlow?

    @Environment(\.dismiss) private var dismiss
    @State private var caseIDs: [String] = []
    @State private var flow: ModerationCaseFlow?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var openingCaseID: String?

    var body: some View {
        NavigationStack {
            Group {
                if let flow {
                    ModerationCaseView(flow: flow, focusNewHolder: false)
                } else {
                    casePicker
                }
            }
            .navigationTitle("Appeal a moderation case")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .disabled(openingCaseID != nil)
                }
            }
        }
    }

    private var casePicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Share your retained Onym identity with the Authority to recover your cases and open an appeal. Only case IDs are returned; your private key never leaves this device.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(3)

                if isLoading {
                    ProgressView("Finding your cases…")
                } else if caseIDs.isEmpty {
                    Text("No appealable cases were found for this identity.")
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                } else {
                    SettingsCard {
                        VStack(spacing: 0) {
                            ForEach(caseIDs, id: \.self) { caseID in
                                Button { openCase(caseID) } label: {
                                    HStack {
                                        Text(caseID)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundStyle(OnymTokens.text)
                                            .lineLimit(1)
                                        Spacer()
                                        if openingCaseID == caseID {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(OnymTokens.text3)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(.plain)
                                .disabled(openingCaseID != nil)
                                .accessibilityIdentifier("moderation.recovery.case.\(caseID)")
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .accessibilityIdentifier("moderation.recovery.error")
                }

            }
            .padding(20)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .task { await loadCases() }
    }

    private func loadCases() async {
        errorMessage = nil
        caseIDs = await lookupCaseIDs()
        isLoading = false
        if caseIDs.isEmpty {
            errorMessage = "The Authority could not find a recoverable case for this identity."
        }
    }

    private func openCase(_ caseID: String) {
        openingCaseID = caseID
        errorMessage = nil
        Task { @MainActor in
            if let resolved = await makeCaseFlow(caseID) {
                flow = resolved
            } else {
                errorMessage = "No active moderation identity is available. Consent to the authority again, then retry."
                openingCaseID = nil
            }
        }
    }
}
