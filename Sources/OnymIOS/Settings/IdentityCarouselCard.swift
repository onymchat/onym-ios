import SwiftUI

/// The unified Settings "Identity" surface: a horizontally-swipeable
/// carousel of every identity's invite-key QR (alias highlighted), where
/// landing on a page makes that identity active (debounced), the last page
/// mints a new identity from an inline name field over a blurred QR, and
/// each identity page carries Share / Backup / Delete under its QR.
///
/// Replaces the three separate Settings cells (Active identity hero, Invite
/// key QR hero, Identities row) with one. Invite-key QRs are pure functions
/// of each summary's `inboxPublicKey`, so every page renders synchronously
/// with no active-identity constraint; `select(_:)` is idempotent, so the
/// scroll-to-activate gesture can fire freely. Backup targets the active
/// identity — which, by the time its button is tapped, is the visible page.
struct IdentityCarouselCard: View {
    @Bindable var flow: IdentitiesFlow
    /// Present the recovery-phrase backup sheet (active identity).
    var onBackup: () -> Void
    /// Present the full-screen invite-key share view for `summary`.
    var onShare: (IdentitySummary) -> Void

    /// Sentinel page tag for the "add new identity" page.
    private static let addTag = "add"

    @State private var selection: String = ""
    @State private var selectTask: Task<Void, Never>?
    @FocusState private var addNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                ForEach(flow.identities) { summary in
                    identityPage(summary)
                        .tag(summary.id.rawValue.uuidString)
                }
                addPage
                    .tag(Self.addTag)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            .frame(height: 420)
            .accessibilityIdentifier("identity.carousel")
            .onChange(of: selection) { _, newValue in settle(on: newValue) }
            .onChange(of: flow.identities.count) { old, new in
                // A just-added identity appends to the list — jump the
                // carousel onto it so the user sees their new QR.
                if new > old, let last = flow.identities.last {
                    selection = last.id.rawValue.uuidString
                }
            }
            .onAppear {
                if selection.isEmpty {
                    selection = flow.currentID?.rawValue.uuidString
                        ?? flow.identities.first?.id.rawValue.uuidString
                        ?? Self.addTag
                }
            }
        }
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .sheet(item: removalBinding) { summary in
            RemoveIdentitySheet(flow: flow, summary: summary)
        }
    }

    // MARK: - Settle → set active (debounced)

    private func settle(on tag: String) {
        selectTask?.cancel()
        guard tag != Self.addTag,
              let summary = flow.identities.first(where: { $0.id.rawValue.uuidString == tag }),
              summary.id != flow.currentID
        else { return }
        selectTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            flow.select(summary.id)
        }
    }

    /// Bridges the flow's `pendingRemoval` to a `sheet(item:)` binding so
    /// dismissing the sheet cancels the pending removal.
    private var removalBinding: Binding<IdentitySummary?> {
        Binding(
            get: { flow.pendingRemoval },
            set: { if $0 == nil { flow.cancelRemoval() } }
        )
    }

    // MARK: - Identity page

    private func identityPage(_ summary: IdentitySummary) -> some View {
        let isActive = summary.id == flow.currentID
        return VStack(spacing: 12) {
            SettingsQRCode(
                value: settingsInviteURL(blsPublicKey: summary.inboxPublicKey),
                size: 190
            )
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isActive ? OnymAccent.blue.color : OnymTokens.hairline,
                        lineWidth: isActive ? 2 : 1))

            VStack(spacing: 3) {
                Text(summary.name)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(isActive ? OnymAccent.blue.color : OnymTokens.text)
                    .lineLimit(1)
                if isActive {
                    Text("ACTIVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(OnymAccent.blue.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(OnymAccent.blue.color.opacity(0.14), in: Capsule())
                } else {
                    Text("Swipe here to switch")
                        .font(.system(size: 11))
                        .foregroundStyle(OnymTokens.text3)
                }
                Text("Start a chat by scanning · BLS \(flow.blsPrefix(of: summary))…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OnymTokens.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 2)
            }

            HStack(spacing: 10) {
                carouselAction(icon: "square.and.arrow.up", title: "Share") {
                    onShare(summary)
                }
                .accessibilityIdentifier("identity.share.\(summary.id.rawValue.uuidString)")
                carouselAction(icon: "key.fill", title: "Backup") {
                    // The visible page is the active identity (set on
                    // settle); backup targets it. Nudge active in case the
                    // debounce hasn't fired yet.
                    flow.select(summary.id)
                    onBackup()
                }
                .accessibilityIdentifier("identity.backup.\(summary.id.rawValue.uuidString)")
                carouselAction(icon: "trash", title: "Delete", destructive: true) {
                    flow.startRemoval(of: summary)
                }
                .accessibilityIdentifier("identity.delete.\(summary.id.rawValue.uuidString)")
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func carouselAction(
        icon: String,
        title: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(destructive ? OnymTokens.red : OnymAccent.blue.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(OnymTokens.surface3,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add-identity page

    private var addPage: some View {
        VStack(spacing: 12) {
            ZStack {
                SettingsQRCode(value: "onym-add-identity", size: 190)
                    .padding(12)
                    .blur(radius: 9)
                    .opacity(0.4)
                    .background(.white.opacity(0.4),
                               in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(OnymTokens.hairline, lineWidth: 1))
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(OnymAccent.blue.color)
            }

            Text("Add identity")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(OnymTokens.text)
            Text("A fresh key — separate contacts and chats from your other identities.")
                .font(.system(size: 12))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            TextField("Name (optional)", text: $flow.pendingName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($addNameFocused)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(OnymTokens.bg,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OnymTokens.hairline, lineWidth: 1))
                .accessibilityIdentifier("identity.add.name_field")

            Button {
                addNameFocused = false
                flow.submitAdd()
            } label: {
                Text("Create identity")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnymTokens.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(OnymAccent.blue.color,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("identity.add.create_button")

            if let error = flow.addError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OnymTokens.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
