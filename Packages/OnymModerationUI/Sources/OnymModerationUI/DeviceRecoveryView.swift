import SwiftUI
import OnymDesign
import OnymModeration

/// The recovery sheet behind `reidentificationRequired`: file a claim
/// for a human moderator, watch its status, and let the flow redeem
/// the grant when one is issued.
public struct DeviceRecoveryView: View {
    @State private var flow: DeviceRecoveryFlow
    @State private var contact = ""
    @State private var statement = ""

    @Environment(\.dismiss) private var dismiss

    public init(flow: DeviceRecoveryFlow) {
        _flow = State(initialValue: flow)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(20)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle(Text("Recover this device", comment: "Device recovery sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                // Resume politely: if a claim is already on file,
                // check it once on appearance.
                await flow.checkClaim()
            }
        }
        .accessibilityIdentifier("moderation.device_recovery")
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .form, .filing:
            claimForm
        case .awaitingReview(let claimId), .checking(let claimId):
            awaitingReview(claimId: claimId)
        case .refused(let reasons):
            refused(reasons: reasons)
        case .redeeming:
            statusBlock(
                icon: "arrow.triangle.2.circlepath",
                title: String(localized: "Applying the moderator's decision…"),
                detail: String(localized: "The device is presenting the signed grant to the enforcement service.")
            )
            ProgressView()
        case .markInForce(let contact, let newHolderURL, let appealURL):
            markInForce(contact: contact, newHolderURL: newHolderURL, appealURL: appealURL)
        case .recovered:
            statusBlock(
                icon: "checkmark.seal",
                title: String(localized: "Device recovered"),
                detail: String(localized: "The record was cleared. Onym will continue in a moment.")
            )
        }
        if let errorMessage = flow.errorMessage {
            Text(errorMessage)
                .font(OnymType.font(size: 13))
                .foregroundStyle(OnymTokens.red)
                .accessibilityIdentifier("moderation.device_recovery.error")
        }
    }

    private var claimForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A person at the moderation authority reviews device-recovery claims. Say how this device came to you and leave a real way to reach you — the moderator may need to verify your account before deciding.", comment: "Device recovery claim form intro")
                .font(OnymType.font(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(3)

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(String(localized: "Contact — email or phone", comment: "Recovery claim contact field"), text: $contact)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("moderation.device_recovery.contact")
                    Divider()
                    TextField(
                        String(localized: "How do you hold this device? (bought used, reset, …)", comment: "Recovery claim statement field"),
                        text: $statement,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                    .accessibilityIdentifier("moderation.device_recovery.statement")
                }
                .padding(16)
            }

            PrimaryButton(action: submit) {
                if case .filing = flow.phase {
                    ProgressView().tint(OnymTokens.onAccent)
                } else {
                    Text("Send to the moderator", comment: "Recovery claim submit button")
                }
            }
            .disabled(isFiling)
            .accessibilityIdentifier("moderation.device_recovery.submit")
        }
    }

    private func awaitingReview(claimId: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBlock(
                icon: "person.badge.clock",
                title: String(localized: "A person is reviewing your claim"),
                detail: String(localized: "The moderator may contact you before deciding. This can take a while — you can close this screen and check back later.")
            )
            Text(claimId)
                .font(OnymType.mono(size: 12))
                .foregroundStyle(OnymTokens.text3)
            PrimaryButton(action: check) {
                if isChecking {
                    ProgressView().tint(OnymTokens.onAccent)
                } else {
                    Text("Check the decision", comment: "Recovery claim poll button")
                }
            }
            .disabled(isChecking)
            .accessibilityIdentifier("moderation.device_recovery.check")
            if flow.errorMessage != nil {
                // The recurring-error exit: a persisted claim the
                // authority no longer knows (re-consent, a pruned
                // claim) would otherwise pin the holder here forever.
                Button {
                    flow.startOver()
                } label: {
                    Text("File a new claim", comment: "Recovery claim start over button")
                        .font(OnymType.font(size: 14, weight: .medium))
                }
                .accessibilityIdentifier("moderation.device_recovery.start_over")
            }
        }
    }

    private func refused(reasons: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBlock(
                icon: "hand.raised",
                title: String(localized: "The moderator refused this claim"),
                detail: reasons
            )
            Button {
                flow.startOver()
            } label: {
                Text("File a new claim", comment: "Recovery claim start over button")
                    .font(OnymType.font(size: 14, weight: .medium))
            }
            .accessibilityIdentifier("moderation.device_recovery.start_over")
        }
    }

    private func markInForce(contact: String, newHolderURL: URL?, appealURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBlock(
                icon: "exclamationmark.shield",
                title: String(localized: "A moderation record still bans this device"),
                detail: String(localized: "The grant stays valid, but nothing moves while a ban stands. Resolve the case with the authority, then check again.")
            )
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(contact)
                        .font(OnymType.font(size: 13))
                        .foregroundStyle(OnymTokens.text)
                    if let appealURL {
                        Link(destination: appealURL) {
                            Text("Appeal the case", comment: "Recovery mark-in-force appeal link")
                        }
                        .accessibilityIdentifier("moderation.device_recovery.appeal")
                    }
                    if let newHolderURL {
                        Link(destination: newHolderURL) {
                            Text("New-holder claim", comment: "Recovery mark-in-force new holder link")
                        }
                        .accessibilityIdentifier("moderation.device_recovery.new_holder")
                    }
                }
                .padding(16)
            }
            PrimaryButton(action: check) {
                Text("Check again", comment: "Recovery mark-in-force re-check button")
            }
        }
    }

    private func statusBlock(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(OnymType.font(size: 28))
                .foregroundStyle(OnymTokens.text2)
            Text(title)
                .font(OnymType.font(size: 17, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(detail)
                .font(OnymType.font(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(3)
        }
    }

    private var isFiling: Bool {
        if case .filing = flow.phase { return true }
        return false
    }

    private var isChecking: Bool {
        if case .checking = flow.phase { return true }
        return false
    }

    private func submit() {
        Task { await flow.submitClaim(contact: contact, statement: statement) }
    }

    private func check() {
        Task { await flow.checkClaim() }
    }
}
