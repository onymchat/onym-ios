import SwiftUI
import OnymDesign
import OnymInbox

/// The screen between an invitation and a join request.
///
/// It exists because arriving is not consenting. A link reaches this app
/// through an exported entry point — another app on the device can open
/// it, and so can a page in a browser — and the request it would send
/// carries this identity's name and its long-term public keys to
/// whoever holds the invite key. Acting on delivery alone let anything
/// that could form a URL disclose all of that silently. So the link
/// resolves to this screen, and only the Send below sends.
///
/// It also earns its place for the person who *did* tap the link: the
/// name they arrive under is the name the founder decides on, and until
/// now they had no chance to set it.
public struct JoinConfirmView: View {
    let confirmation: PendingChatsFlow.JoinConfirmation
    /// Called with the typed name. The caller owns the send.
    let onSend: (String) -> Void
    let onCancel: () -> Void

    public init(
        confirmation: PendingChatsFlow.JoinConfirmation,
        onSend: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.confirmation = confirmation
        self.onSend = onSend
        self.onCancel = onCancel
    }

    @State private var label: String = ""
    @State private var isSending = false
    @FocusState private var nameFocused: Bool

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if let message = confirmation.invitationMessage,
                       !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        invitationCard(message)
                    }
                    nameField
                    disclosure
                    sendButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(OnymTokens.bg.ignoresSafeArea())
            .navigationTitle("Join this chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("join_confirm.cancel")
                }
            }
        }
        .onAppear {
            if label.isEmpty { label = confirmation.suggestedLabel }
        }
    }

    private var displayName: String {
        let name = confirmation.groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return String(localized: "(Unnamed)") }
        return name
    }

    private var header: some View {
        VStack(spacing: 8) {
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
            let alias = confirmation.inviterAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty {
                Text("\(alias) invited you")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
        }
    }

    private func invitationCard(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(OnymTokens.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .textSelection(.enabled)
            .accessibilityIdentifier("join_confirm.invitation_message")
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask to join as")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            TextField("Your name in this chat", text: $label)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .padding(12)
                .background(OnymTokens.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(OnymTokens.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("join_confirm.name_field")
            // The name rides with this join only. One identity can be
            // "Sam" in a book club and "S." in a tenants' group without
            // either being a second identity.
            Text("Only this chat sees this name. It doesn\u{2019}t rename your identity.")
                .font(.system(size: 11))
                .foregroundStyle(OnymTokens.text2)
        }
    }

    /// Names what leaves the device and who receives it, in that order,
    /// while there is still a way out.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Sending shares your name and this identity\u{2019}s public keys with whoever holds this invite.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            } icon: {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            }
            row("group", value: shortHex(confirmation.groupIDHex))
            row("invite key", value: shortHex(hex(confirmation.introPublicKey)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OnymTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("join_confirm.disclosure")
    }

    private var sendButton: some View {
        Button {
            isSending = true
            onSend(label.trimmingCharacters(in: .whitespacesAndNewlines))
        } label: {
            Text(isSending
                 ? String(localized: "Sending\u{2026}")
                 : String(localized: "Send join request"))
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(OnymAccent.blue.color.opacity(canSend ? 1.0 : 0.5))
                .foregroundStyle(OnymTokens.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canSend)
        .accessibilityIdentifier("join_confirm.send")
    }

    /// A name is required: an empty one reaches the founder as a blank
    /// row they are asked to admit.
    private var canSend: Bool {
        !isSending && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func row(_ key: String, value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(OnymTokens.text2)
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Enough to compare against what the host is showing, short enough
    /// to read out loud.
    private func shortHex(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return value.prefix(6) + "\u{2026}" + value.suffix(6)
    }
}
