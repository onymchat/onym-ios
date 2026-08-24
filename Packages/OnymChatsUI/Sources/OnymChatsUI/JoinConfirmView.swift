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
    /// Unticked until the person ticks it. Only ever gates Send for a
    /// group that has rules — see `canSend`.
    @State private var agreedToRules = false

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    // Same field, two names: since the rename, a
                    // group's invitation message *is* its rules, so an
                    // offer whose text became the rules card must not
                    // also draw it as a greeting. Only a message that
                    // says something different earns its own card.
                    if let message = confirmation.invitationMessage,
                       !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       message.trimmingCharacters(in: .whitespacesAndNewlines)
                           != confirmation.rules {
                        invitationCard(message)
                    }
                    if let rules = confirmation.rules {
                        rulesCard(rules)
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
                .font(OnymType.font(size: 20, weight: .bold))
                .foregroundStyle(OnymTokens.text)
            let alias = confirmation.inviterAlias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty {
                Text("\(alias) invited you")
                    .font(OnymType.font(size: 13))
                    .foregroundStyle(OnymTokens.text2)
            }
        }
    }

    private func invitationCard(_ message: String) -> some View {
        Text(message)
            .font(OnymType.font(size: 14))
            .foregroundStyle(OnymTokens.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(OnymTokens.surface2)
            .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
            .textSelection(.enabled)
            .accessibilityIdentifier("join_confirm.invitation_message")
    }

    /// The rules, and the tick that turns reading them into agreeing.
    ///
    /// Send signs this exact text, so it is shown in full rather than
    /// truncated behind a "more": a signature over words that were
    /// folded away is not much of an agreement. The text is
    /// founder-supplied and untrusted, hence rendered plain — no
    /// markdown, no links to follow.
    private func rulesCard(_ rules: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Group rules")
                .font(OnymType.font(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Text(rules)
                .font(OnymType.font(size: 14))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier("join_confirm.rules_text")
            Divider().overlay(OnymTokens.hairline)
            Toggle(isOn: $agreedToRules) {
                Text("I agree to these rules")
                    .font(OnymType.font(size: 13, weight: .medium))
                    .foregroundStyle(OnymTokens.text)
            }
            .tint(OnymAccent.blue.color)
            .accessibilityIdentifier("join_confirm.agree_toggle")
            // Said plainly, because it is the part that outlives the
            // tap: the founder keeps this, and can show it.
            Text("Your agreement is signed with this identity\u{2019}s key and sent with your request.")
                .font(OnymType.font(size: 11))
                .foregroundStyle(OnymTokens.text2)
        }
        .padding(14)
        .background(OnymTokens.surface2)
        .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
        .overlay(
            RoundedRectangle(cornerRadius: OnymRadius.inset)
                .stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("join_confirm.rules")
    }

    /// Pre-filled, never blank: the identity's own name is the answer
    /// almost every time, so joining is Send and nothing else. The field
    /// is here for the times it isn't — a name you'd rather this room
    /// used — not as a question to answer first.
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask to join as")
                .font(OnymType.font(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            TextField("Your name in this chat", text: $label)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(12)
                .background(OnymTokens.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: OnymRadius.inset)
                        .stroke(OnymTokens.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
                .accessibilityIdentifier("join_confirm.name_field")
            // The name rides with this join only. One identity can be
            // "Sam" in a book club and "S." in a tenants' group without
            // either being a second identity.
            Text("Only this chat sees this name. It doesn\u{2019}t rename your identity.")
                .font(OnymType.font(size: 11))
                .foregroundStyle(OnymTokens.text2)
        }
    }

    /// Names what leaves the device and who receives it, in that order,
    /// while there is still a way out.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Sending shares your name and this identity\u{2019}s public keys with whoever holds this invite.")
                    .font(OnymType.font(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            } icon: {
                Image(systemName: "person.badge.key")
                    .font(OnymType.font(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            }
            if confirmation.rules != nil {
                Label {
                    Text("Your signed agreement to the rules goes with it.")
                        .font(OnymType.font(size: 12))
                        .foregroundStyle(OnymTokens.text2)
                } icon: {
                    Image(systemName: "signature")
                        .font(OnymType.font(size: 12))
                        .foregroundStyle(OnymTokens.text2)
                }
            }
            row("group", value: shortHex(confirmation.groupIDHex))
            row("invite key", value: shortHex(hex(confirmation.introPublicKey)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OnymTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
        .accessibilityIdentifier("join_confirm.disclosure")
    }

    private var sendButton: some View {
        Button {
            isSending = true
            onSend(label.trimmingCharacters(in: .whitespacesAndNewlines))
        } label: {
            Text(isSending
                 ? String(localized: "Sending\u{2026}")
                 : confirmation.rules == nil
                    ? String(localized: "Send join request")
                    : String(localized: "Agree and send request"))
                .font(OnymType.font(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(OnymAccent.blue.color.opacity(canSend ? 1.0 : 0.5))
                .foregroundStyle(OnymTokens.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: OnymRadius.inset))
        }
        .disabled(!canSend)
        .accessibilityIdentifier("join_confirm.send")
    }

    /// A name is required: an empty one reaches the founder as a blank
    /// row they are asked to admit. It is pre-filled from the identity,
    /// so this only bites if someone deliberately clears it.
    ///
    /// The rules tick is required only when there are rules. A group
    /// that asks nothing of its joiners keeps that one-tap join: there
    /// is nothing to affirm, and a tick standing for nothing is
    /// friction that teaches people to tick without reading.
    private var canSend: Bool {
        guard !isSending,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return confirmation.rules == nil || agreedToRules
    }

    /// `LocalizedStringKey`, not `String`: passing a `String` picks
    /// `Text`'s non-localizing overload, and these two labels rendered
    /// English under every locale while their catalog entries sat
    /// unused. `test_localizable_xcstrings_everyKey_hasEnAndRu` can't
    /// see this — the key is there, the lookup is what was missing.
    private func row(_ key: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(key)
                .font(OnymType.font(size: 11, weight: .semibold))
                .foregroundStyle(OnymTokens.text3)
            Spacer()
            Text(value)
                .font(OnymType.mono(size: 12))
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
