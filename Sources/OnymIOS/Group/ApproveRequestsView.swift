import SwiftUI

/// Modal surface listing pending join requests with Approve / Decline
/// actions. Driven by the shared `ApproveRequestsFlow`. Empty state
/// is the steady state for users with no outstanding invite links.
///
/// Trust framing: each row shows the joiner's self-asserted alias
/// alongside the inbox-pubkey hex prefix as an out-of-band
/// fingerprint, matching the guidance documented on
/// `JoinRequestPayload`. Inviters who care about provenance can
/// verify the prefix with the joiner over a side channel before
/// approving.
struct ApproveRequestsView: View {
    @Bindable var flow: ApproveRequestsFlow
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let success = flow.lastSuccessMessage {
                successBanner(success)
            }
            if let error = flow.lastError {
                errorBanner(error)
            }
            if flow.pending.isEmpty {
                emptyState
            } else {
                requestList
            }
        }
        .background(OnymTokens.bg)
    }

    // MARK: - Success

    private func successBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(OnymTokens.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Approved on chain")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(OnymTokens.green.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("approve_requests.success_banner")
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Close")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text2)
            }
            .accessibilityIdentifier("approve_requests.close_button")
            Spacer()
            Text("Join requests")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
            Spacer().frame(width: 60)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OnymTokens.red)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                flow.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OnymTokens.text2)
            }
            .accessibilityIdentifier("approve_requests.error_dismiss")
        }
        .padding(12)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(OnymTokens.red.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("approve_requests.error_banner")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(OnymTokens.text3)
            Text("No pending requests")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text("People who tap one of your invite links show up here.")
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("approve_requests.empty")
    }

    // MARK: - Request list

    private var requestList: some View {
        ScrollView {
            VStack(spacing: 12) {
                Spacer().frame(height: 8)
                ForEach(flow.pending) { request in
                    requestCard(request)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func requestCard(_ request: JoinRequestApprover.PendingRequest) -> some View {
        let inFlight = flow.isInFlight(request.id)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(displayAlias(request.joinerDisplayLabel))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("wants to join \u{201C}\(request.groupName ?? "Unknown group")\u{201D}")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
            fingerprintRow(label: "inbox", value: hexPrefix(request.joinerInboxPublicKey))
            HStack(spacing: 8) {
                Button {
                    flow.decline(request.id)
                } label: {
                    Text("Decline")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(OnymTokens.surface3)
                        .foregroundStyle(OnymTokens.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityIdentifier("approve_requests.decline_button.\(request.id)")
                .disabled(request.groupName == nil || inFlight)
                Button {
                    flow.approve(request.id)
                } label: {
                    HStack(spacing: 6) {
                        if inFlight {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(OnymTokens.onAccent)
                                .scaleEffect(0.8)
                        }
                        Text(inFlight ? "Anchoring on chain\u{2026}" : "Approve")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(OnymAccent.blue.color.opacity(inFlight ? 0.7 : 1.0))
                    .foregroundStyle(OnymTokens.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityIdentifier("approve_requests.approve_button.\(request.id)")
                .disabled(request.groupName == nil || inFlight)
            }
            if inFlight {
                // The on-chain admit ceremony is multi-second
                // (PLONK proving + relayer roundtrip + Stellar tx
                // confirmation) — surface that explicitly so the
                // admin doesn't think the tap was lost.
                Text("Generating proof and updating the on-chain commitment. This usually takes a few seconds.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
                    .accessibilityIdentifier("approve_requests.in_flight_hint.\(request.id)")
            } else if request.groupName == nil {
                Text("This request is for a group that isn\u{2019}t on this device. Decline to clear it.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            }
        }
        .padding(14)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("approve_requests.row.\(request.id)")
    }

    private func fingerprintRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(OnymTokens.text2)
        }
    }

    // MARK: - Formatting

    private func displayAlias(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(unnamed)" : trimmed
    }

    private func hexPrefix(_ data: Data, count: Int = 8) -> String {
        let prefix = data.prefix(count)
        return prefix.map { String(format: "%02x", $0) }.joined() + "\u{2026}"
    }
}

/// Toolbar entry-point — a small icon with a numeric badge when there
/// are pending requests. Tapping presents the modal `ApproveRequestsView`.
/// Always shown so the surface is discoverable even before the first
/// request lands.
struct ApproveRequestsToolbarButton: View {
    @Bindable var flow: ApproveRequestsFlow
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 17))
                if !flow.pending.isEmpty {
                    Text("\(flow.pending.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(OnymTokens.red))
                        .offset(x: 8, y: -6)
                        .accessibilityIdentifier("approve_requests.toolbar_badge")
                }
            }
        }
        .accessibilityLabel("Join requests")
        .accessibilityIdentifier("approve_requests.toolbar_button")
        .sheet(isPresented: $showSheet) {
            ApproveRequestsView(flow: flow, onClose: { showSheet = false })
        }
    }
}
