import SwiftUI

/// Per-identity drill-down. Big avatar + invite-key QR hero,
/// "Set as active" / "Share invite key" rows, and a destructive
/// remove row at the bottom. The backup card is a placeholder for the
/// upcoming per-identity backup wiring — until then, "Back up now"
/// surfaces the global recovery phrase flow on the active identity
/// (the only one with secrets in keychain).
struct IdentityDetailView: View {
    @Bindable var flow: IdentitiesFlow
    let summary: IdentitySummary

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    private var isActive: Bool { summary.id == flow.currentID }

    /// Live name from `flow.identities` so the hero + nav title reflect
    /// a successful rename without re-presenting the screen. The
    /// `summary` value captured at NavigationLink push time would
    /// otherwise stay frozen.
    private var displayName: String {
        flow.identities.first { $0.id == summary.id }?.name ?? summary.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                inviteCard
                SettingsFootnote("Anyone with this code can start a chat with you. The chat itself is end-to-end encrypted.")

                SettingsSectionLabel("STATE")
                SettingsCard {
                    SettingsRow(
                        title: "Set as active",
                        hasChevron: !isActive,
                        onTap: isActive ? nil : { flow.select(summary.id) }
                    ) {
                        SettingsIconTile(symbol: "checkmark.circle.fill", bg: SettingsTile.green)
                    } right: {
                        if isActive {
                            Text("Active")
                                .font(.system(size: 14.5))
                                .foregroundStyle(OnymTokens.text2)
                        }
                    }

                    Button { showShare = true } label: {
                        SettingsRow(
                            title: "Share invite key",
                            subtitle: "QR code or link",
                            last: true
                        ) {
                            SettingsIconTile(symbol: "square.and.arrow.up", bg: SettingsTile.indigo)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("identity.share_row.\(summary.id)")
                }

                SettingsSectionLabel("ADVANCED")
                SettingsCard {
                    SettingsRow(
                        title: "Copy public key",
                        subtitle: "BLS \(flow.blsPrefix(of: summary))…",
                        subtitleMono: true,
                        hasChevron: false,
                        onTap: {
                            UIPasteboard.general.string = summary.blsPublicKey
                                .map { String(format: "%02x", $0) }.joined()
                        }
                    ) {
                        SettingsIconTile(symbol: "doc.on.doc.fill", bg: SettingsTile.gray)
                    }
                    SettingsRow(
                        title: "Delete identity",
                        titleColor: OnymTokens.red,
                        hasChevron: false,
                        last: true,
                        onTap: { flow.startRemoval(of: summary) }
                    ) {
                        SettingsIconTile(symbol: "trash.fill", bg: SettingsTile.red)
                    }
                }

                SettingsFootnote("Deleting an identity removes its keys from this device. If you’ve backed up the recovery phrase, you can restore it later.")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("identity.detail.\(summary.id)")
        .sheet(isPresented: $showShare) {
            NavigationStack {
                ShareKeyView(identity: summary, blsPrefix: flow.blsPrefix(of: summary))
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isActive
                          ? AnyShapeStyle(LinearGradient(
                              colors: [
                                  Color.dynamic(light: Color(red: 0.933, green: 0.961, blue: 1.0),
                                                dark: OnymAccent.blue.color.opacity(0.20)),
                                  Color.dynamic(light: Color(red: 0.835, green: 0.910, blue: 0.996),
                                                dark: OnymAccent.blue.color.opacity(0.10))
                              ],
                              startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(OnymTokens.surface3))
                    .frame(width: 96, height: 96)
                    .overlay(Circle().stroke(isActive ? OnymAccent.blue.color : .clear, lineWidth: 2))
                    .overlay(OnymMark(size: 64,
                                       color: isActive ? OnymAccent.blue.color : SettingsTile.gray))
            }
            .padding(.top, 8)

            EditableIdentityName(currentName: displayName) { newName in
                flow.rename(summary.id, newName: newName)
            }
            .padding(.top, 14)

            Text("BLS \(flow.blsPrefix(of: summary))…")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(OnymTokens.text2)

            if isActive {
                Text("Active identity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OnymTokens.green)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    /// Cap on the editable display alias — matches the iOS prototype's
    /// `e.target.value.slice(0, 30)`. The repository accepts any length;
    /// the field rejects further input past the cap.
    fileprivate static let maxIdentityNameLength = 30

    private var inviteCard: some View {
        Group {
            SettingsSectionLabel("INVITE KEY")
            SettingsCard {
                VStack(spacing: 14) {
                    SettingsQRCode(
                        value: settingsInviteURL(inboxPublicKey: summary.inboxPublicKey),
                        size: 200
                    )
                    .padding(12)
                    .background(OnymTokens.surface2,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(OnymTokens.hairline, lineWidth: 1))

                    Text("Scan with Onym on another device to open a private chat with this identity.")
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.text2)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 280)

                    Text(settingsInviteURL(inboxPublicKey: summary.inboxPublicKey))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(OnymTokens.text2)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(OnymTokens.surface3,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 16)

                SettingsRowDivider(inset: 16)

                HStack(spacing: 0) {
                    SettingsTextButton(
                        title: "Copy link",
                        systemImage: "doc.on.doc",
                        foreground: OnymAccent.blue.color
                    ) {
                        UIPasteboard.general.string =
                            settingsInviteURL(inboxPublicKey: summary.inboxPublicKey)
                    }
                    .accessibilityIdentifier("identity.copy_link.\(summary.id)")

                    Rectangle().fill(OnymTokens.hairlineStrong).frame(width: 0.5)

                    ShareLink(item: settingsInviteURL(inboxPublicKey: summary.inboxPublicKey)) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(OnymAccent.blue.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("identity.share_link.\(summary.id)")
                }
            }
        }
    }
}

/// Tap-to-edit identity alias. Renders `currentName` as a clickable
/// pill with a small edit pencil; tap → inline `TextField` with a
/// 1.5-pt blue border, autofocus, and a 30-char cap. Commits on
/// Return (`.submitLabel(.done)`) or focus loss; commit-blank /
/// commit-unchanged is a silent no-op (the repository rejects too).
///
/// Mirrors the iOS prototype's hero-name edit affordance
/// (`settings.jsx` lines 840–865) and the Android port in
/// `IdentityDetailScreen.EditableIdentityName`.
private struct EditableIdentityName: View {
    let currentName: String
    let onSave: (String) -> Void

    @State private var editing = false
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $draft)
                .focused($focused)
                .submitLabel(.done)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(OnymTokens.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(OnymAccent.blue.color, lineWidth: 1.5)
                )
                .onChange(of: draft) { _, newValue in
                    if newValue.count > IdentityDetailView.maxIdentityNameLength {
                        draft = String(newValue.prefix(IdentityDetailView.maxIdentityNameLength))
                    }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onSubmit { commit() }
                .onAppear {
                    draft = currentName
                    focused = true
                }
                .accessibilityIdentifier("identity_detail.name_field")
        } else {
            Button {
                editing = true
            } label: {
                HStack(spacing: 6) {
                    Text(currentName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(OnymTokens.text)
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OnymTokens.text2.opacity(0.55))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Rename identity"))
            .accessibilityIdentifier("identity_detail.name_edit")
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else {
            draft = currentName
            return
        }
        onSave(trimmed)
    }
}
