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
    let makeDeviceRecoveryFlow: (@MainActor () async -> DeviceRecoveryFlow)?

    /// Both recovery paths present from this screen. One `sheet(item:)`
    /// over one enum, deliberately: two `.sheet` modifiers live on the
    /// same view here, and SwiftUI has a long history of only honoring
    /// one of them.
    private enum ActiveSheet: Identifiable {
        case caseAppeal
        case deviceRecovery(DeviceRecoveryFlow)

        var id: String {
            switch self {
            case .caseAppeal:
                return "caseAppeal"
            case .deviceRecovery(let flow):
                return "deviceRecovery-\(ObjectIdentifier(flow))"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var isRetrying = false
    @State private var retryMessage: String?

    public init(
        reason: CheckRequiredReason,
        onRetry: @escaping @MainActor () async -> Void,
        lookupRecoveryCaseIDs: (@MainActor () async -> [String])? = nil,
        makeRecoveryCaseFlow: (@MainActor (String) async -> ModerationCaseFlow?)? = nil,
        makeDeviceRecoveryFlow: (@MainActor () async -> DeviceRecoveryFlow)? = nil
    ) {
        self.reason = reason
        self.onRetry = onRetry
        self.lookupRecoveryCaseIDs = lookupRecoveryCaseIDs
        self.makeRecoveryCaseFlow = makeRecoveryCaseFlow
        self.makeDeviceRecoveryFlow = makeDeviceRecoveryFlow
    }

    public var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(OnymType.font(size: 40))
                .foregroundStyle(OnymTokens.text2)
            Text("Verification required")
                .font(OnymType.font(size: 20, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(message)
                .font(OnymType.font(size: 14))
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
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .accessibilityIdentifier("moderation.gate_required.retry_result")
            }
            if reason == .reidentificationRequired, let makeDeviceRecoveryFlow {
                SettingsPrimaryButton(action: {
                    Task { @MainActor in
                        activeSheet = .deviceRecovery(await makeDeviceRecoveryFlow())
                    }
                }) {
                    Text("Ask a moderator to recover this device")
                }
                .padding(.horizontal, 48)
                .padding(.top, 8)
                .accessibilityIdentifier("moderation.gate_required.recover")
            }
            if reason == .reidentificationRequired,
               lookupRecoveryCaseIDs != nil,
               makeRecoveryCaseFlow != nil {
                Button("Appeal by case ID") { activeSheet = .caseAppeal }
                    .font(OnymType.font(size: 14, weight: .medium))
                    .foregroundStyle(OnymTokens.text)
                    .accessibilityIdentifier("moderation.gate_required.appeal")
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnymTokens.surface.ignoresSafeArea())
        .accessibilityIdentifier("moderation.gate_required")
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .caseAppeal:
                if let lookupRecoveryCaseIDs, let makeRecoveryCaseFlow {
                    RecoveryAppealView(
                        lookupCaseIDs: lookupRecoveryCaseIDs,
                        makeCaseFlow: makeRecoveryCaseFlow
                    )
                }
            case .deviceRecovery(let flow):
                DeviceRecoveryView(flow: flow)
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
            return String(localized: "Device verification isn't available in this environment. Plain Simulator runs answer the gate with a stub, so this appears only when pointed at a real enforcement deployment; use a physical device for the full verification loop.")
        case .reidentificationRequired:
            return String(localized: "This device carries a moderation mark, but this install cannot verify its original identity. Reinstalling or retrying will not fix this. Ask a moderator to recover the device below — a person reviews your claim and decides.")
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
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(3)

                if isLoading {
                    ProgressView("Finding your cases…")
                } else if caseIDs.isEmpty {
                    Text("No appealable cases were found for this identity.")
                        .font(OnymType.font(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                } else {
                    SettingsCard {
                        VStack(spacing: 0) {
                            ForEach(caseIDs, id: \.self) { caseID in
                                Button { openCase(caseID) } label: {
                                    HStack {
                                        Text(caseID)
                                            .font(OnymType.mono(size: 13))
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
                        .font(OnymType.font(size: 13))
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
