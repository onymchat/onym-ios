import SwiftUI
import OnymDesign
import OnymInbox

/// The thread behind a chat you are not in yet.
///
/// It is deliberately thread-shaped rather than a form: the row sits in
/// the chats list next to real conversations, so tapping it has to land
/// somewhere that reads like a conversation which hasn't started. The
/// founder's invitation message is the one thing already said, and the
/// rest of the screen is the wait — the same states the Invitations
/// sheet used to show, in the place people actually look.
///
/// When the founder approves, the group materializes, the pending row is
/// consumed and this screen is replaced by the real thread — whose first
/// row is the "You joined X" notice the dispatcher mints on
/// materialization. Nothing here writes that notice; this screen just
/// stops existing.
struct PendingChatThreadView: View {
    @Bindable var flow: PendingChatsFlow
    let rowID: String

    var body: some View {
        Group {
            if let row = flow.row(id: rowID) {
                content(row)
            } else {
                // The row was consumed while the screen was open — the
                // group landed, or the user dismissed it from the list.
                // The chats list behind this is already correct.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(OnymTokens.bg.ignoresSafeArea())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("pending_chat.thread")
    }

    private var displayName: String {
        let name = flow.row(id: rowID)?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return String(localized: "(Unnamed)") }
        return name
    }

    @ViewBuilder
    private func content(_ row: PendingChatsFlow.Row) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = flow.lastError {
                    errorBanner(error)
                }
                header(row)
                if let message = row.invitationMessage,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    invitationCard(message)
                }
                stateBlock(row)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    private func header(_ row: PendingChatsFlow.Row) -> some View {
        VStack(spacing: 10) {
            OnymGroupAvatar(
                size: 72,
                accent: OnymAccent.blue.color,
                ringPulse: false,
                spinning: false,
                brand: false,
                imageData: nil
            )
            Text(displayName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(OnymTokens.text)
            if !row.inviterAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("\(row.inviterAlias) invited you")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
        }
        .padding(.top, 8)
    }

    /// The founder's own words, rendered as the one message this thread
    /// already has.
    private func invitationCard(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(OnymTokens.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .textSelection(.enabled)
            .accessibilityIdentifier("pending_chat.invitation_message")
    }

    @ViewBuilder
    private func stateBlock(_ row: PendingChatsFlow.Row) -> some View {
        VStack(spacing: 12) {
            switch row.state {
            case .offered:
                Text("Accepting sends a request. The founder decides who comes in, so you'll be in once they approve.")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
                primaryButton(
                    title: row.isSending
                        ? String(localized: "Sending\u{2026}")
                        : String(localized: "Accept"),
                    showsSpinner: row.isSending,
                    identifier: "pending_chat.accept",
                    disabled: row.isSending
                ) {
                    flow.accept(row.id)
                }
            case .waiting:
                waiting(
                    title: String(localized: "Waiting until you\u{2019}re in"),
                    detail: String(localized: "The founder has to let you in before this chat opens. It appears here the moment they do \u{2014} you don\u{2019}t have to keep this screen open.")
                )
            case .chainSettling:
                waiting(
                    title: String(localized: "Almost in"),
                    detail: String(localized: "Waiting for the group to be confirmed on chain\u{2026} This usually takes a few seconds.")
                )
            case .founderUnreachable, .chainUnreachable, .chainNotConfigured, .sendFailed:
                stuck(row)
            }
        }
        .padding(.top, 4)
        .accessibilityIdentifier("pending_chat.state")
    }

    private func waiting(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .padding(.top, 16)
        .accessibilityIdentifier("pending_chat.waiting")
    }

    /// One sentence per reason, because the reasons need different
    /// things from the reader — naming the founder for a failure that is
    /// entirely local sends people to wait on somebody who cannot help.
    /// Same wording the Invitations sheet carried, one screen over.
    private func stuck(_ row: PendingChatsFlow.Row) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(OnymTokens.text2)
            Text(stuckMessage(row.state))
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            primaryButton(
                title: row.isSending
                    ? String(localized: "Sending\u{2026}")
                    : String(localized: "Retry"),
                showsSpinner: row.isSending,
                identifier: "pending_chat.retry",
                disabled: row.isSending
            ) {
                flow.retry(row.id)
            }
        }
        .padding(.top, 16)
        .accessibilityIdentifier("pending_chat.stuck")
    }

    private func stuckMessage(_ state: PendingChatsFlow.State) -> String {
        switch state {
        case .chainNotConfigured:
            // Usually a cold-install race rather than a wrong setting:
            // the relayer and contract lists arrive from the network
            // shortly after launch, and Retry re-fetches them.
            String(localized: "Still setting up this device\u{2019}s connection to the chain. Tap Retry in a moment.")
        case .chainUnreachable:
            String(localized: "Couldn\u{2019}t reach the chain to verify this group. Check your connection and try again.")
        case .sendFailed(let reason) where !reason.isEmpty:
            reason
        case .sendFailed:
            String(localized: "Your request didn\u{2019}t go out. Tap Retry to send it again.")
        default:
            String(localized: "Couldn\u{2019}t verify \u{2014} the admin is offline. The group stays hidden until it can be verified on chain.")
        }
    }

    private func primaryButton(
        title: String,
        showsSpinner: Bool,
        identifier: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if showsSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(OnymTokens.onAccent)
                        .scaleEffect(0.8)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(OnymAccent.blue.color.opacity(disabled ? 0.7 : 1.0))
            .foregroundStyle(OnymTokens.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OnymTokens.red)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(OnymTokens.text)
            Spacer()
            Button {
                flow.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnymTokens.text2)
            }
        }
        .padding(12)
        .background(OnymTokens.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
