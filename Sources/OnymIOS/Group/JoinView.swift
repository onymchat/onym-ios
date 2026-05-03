import SwiftUI

/// Post-deeplink-tap "Join this chat" surface. Replaces PR-6's
/// `JoinInviteCapturedPlaceholderView` once both the joiner-side
/// (this view) and the inviter-side approver (PR-4 backend, future
/// inviter-side approval UI) are wired.
struct JoinView: View {
    @Bindable var flow: JoinFlow
    let onClose: () -> Void

    @State private var displayLabel: String = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 16)
                    hero
                    diagnostics
                    stateBody(for: flow.state)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(OnymTokens.bg)
        .onAppear {
            if displayLabel.isEmpty { displayLabel = flow.suggestedDisplayLabel }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Cancel")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnymTokens.text2)
            }
            .accessibilityIdentifier("join.cancel_button")
            Spacer()
            Text("Join chat")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Spacer()
            Spacer().frame(width: 60)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 48))
                .foregroundStyle(OnymAccent.blue.color)
            Text(flow.capability.groupName ?? "Join this chat")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(OnymTokens.text)
            Text("Send a request — the host will see it and decide whether to let you in.")
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("inviter", value: hexPrefix(flow.capability.introPublicKey))
            row("group_id", value: hexPrefix(flow.capability.groupId))
        }
        .padding(14)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func stateBody(for state: JoinFlow.State) -> some View {
        switch state {
        case .ready:
            VStack(spacing: 12) {
                TextField("Display name", text: $displayLabel)
                    .padding(12)
                    .background(OnymTokens.surface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(OnymTokens.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("join.display_label_field")
                Button {
                    flow.send(displayLabel: displayLabel)
                } label: {
                    Text("Send join request")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OnymAccent.blue.color)
                        .foregroundStyle(OnymTokens.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("join.send_button")
                .disabled(displayLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 8)
        case .sending:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Sending request…")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
            .padding(.top, 24)
            .accessibilityIdentifier("join.sending")
        case .awaitingApproval:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Waiting for the host to approve…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Keep this screen open. The chat will appear automatically once they approve.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 24)
            .accessibilityIdentifier("join.awaiting_approval")
        case .approved(let group):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(OnymTokens.green)
                Text("You're in!")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OnymTokens.text)
                Text("\"\(group.name)\" is now in your chats list.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
                Button(action: onClose) {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OnymAccent.blue.color)
                        .foregroundStyle(OnymTokens.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("join.done_button")
            }
            .padding(.top, 24)
        case .failed(let reason):
            VStack(spacing: 12) {
                Text(reason)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                Button {
                    flow.send(displayLabel: displayLabel)
                } label: {
                    Text("Try again")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OnymAccent.blue.color)
                        .foregroundStyle(OnymTokens.onAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("join.retry_button")
            }
            .padding(.top, 24)
        }
    }

    private func row(_ key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(OnymTokens.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hexPrefix(_ data: Data, count: Int = 8) -> String {
        let prefix = data.prefix(count)
        return prefix.map { String(format: "%02x", $0) }.joined() + "…"
    }
}
