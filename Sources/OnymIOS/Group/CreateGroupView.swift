import SwiftUI

/// Top-level view for the Create Group flow. Pixel-port of the
/// Claude Designed reference (`onym-ios/project/Onym Create Group.html`)
/// adapted to PR-C scope:
///
/// - Tyranny is the only selectable governance type. The 1-on-1 and
///   Anarchy cards stay in the picker but are dimmed with a "Soon"
///   pill — they ship in a follow-up slice.
/// - The "Add People" screen replaces the design's Contacts list with
///   a paste-only invitee list (Contacts framework is out of scope).
/// - The "Invite by Inbox Key" screen drops the Scan QR button (no
///   camera entitlement in the MVP).
/// - The Creating screen wires its step list to real
///   `CreateGroupProgress` events from the interactor.
/// - The Success screen replaces "Open" + "Invite more" with a single
///   "Done" CTA — there's no chat screen yet, and member-add via
///   `update_commitment` is out of scope.
///
/// Hosted as a `.fullScreenCover` from Settings (see
/// `SettingsView.tappedCreateGroup`).
struct CreateGroupView: View {
    @State var flow: CreateGroupFlow
    let makeShareInviteFlow: @MainActor () -> ShareInviteFlow
    @State private var shareInviteFlow: ShareInviteFlow?

    init(
        flow: CreateGroupFlow,
        makeShareInviteFlow: @escaping @MainActor () -> ShareInviteFlow
    ) {
        _flow = State(wrappedValue: flow)
        self.makeShareInviteFlow = makeShareInviteFlow
    }

    var body: some View {
        ZStack {
            OnymTokens.bg.ignoresSafeArea()
            currentScreen
                .id(flow.route)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.18), value: flow.route)
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch flow.route {
        case .step1: CreateGroupStep1View(flow: flow)
        case .step2: CreateGroupStep2View(flow: flow)
        case .inviteByKey: CreateGroupInviteByKeyView(flow: flow)
        case .creating: CreateGroupCreatingView(flow: flow)
        case .success: CreateGroupSuccessView(flow: flow)
        case .shareInvite:
            if let group = flow.createdGroup {
                shareInviteScreen(group: group)
            } else {
                // Defensive: route should only be entered when
                // `createdGroup` is non-nil (button is disabled
                // otherwise). Fall back to the success screen.
                CreateGroupSuccessView(flow: flow)
            }
        }
    }

    @ViewBuilder
    private func shareInviteScreen(group: ChatGroup) -> some View {
        // Construct the ShareInviteFlow lazily on first appearance and
        // hold it for the lifetime of the parent. Re-entering the
        // screen reuses the same flow so its `.failed` state survives
        // a Done → Back round-trip.
        let f = shareInviteFlow ?? makeShareInviteFlow()
        ShareInviteView(
            groupID: group.id,
            flow: f,
            onDone: flow.tappedDone
        )
        .onAppear { if shareInviteFlow == nil { shareInviteFlow = f } }
    }
}

// MARK: - Shared bits

/// Centered title block used at the top of every screen
/// (title-only nav per the design — back/cancel live in the footer).
private struct OnymNavTitle: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(OnymTokens.text3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct OnymSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.88)
            .foregroundStyle(OnymTokens.text3)
            .padding(.horizontal, 4)
            .padding(.top, 22)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Primary footer button (52pt tall, full-width, accent fill).
private struct OnymPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    var accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .tracking(-0.16)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(enabled ? OnymTokens.onAccent : OnymTokens.text3)
                .background(enabled ? accent : OnymTokens.surface3)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: enabled ? accent.opacity(0.30) : .clear, radius: 12, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Quiet text-only button shown under the primary CTA (Cancel / Back).
private struct OnymQuietButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(OnymTokens.text2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 1: name + accent + governance

private struct CreateGroupStep1View: View {
    @Bindable var flow: CreateGroupFlow
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            OnymNavTitle(title: "New Group", subtitle: "Step 1 of 2")
            ScrollView {
                VStack(spacing: 0) {
                    avatar
                    nameField
                    nameFootnote
                    OnymSectionLabel(text: "Accent color")
                    accentRow
                    OnymSectionLabel(text: "How it\u{2019}s run")
                    governancePicker
                    selectedExplanation
                    encryptedFooterCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            footer
        }
    }

    private var accentColor: Color { flow.accent.color }

    private var avatar: some View {
        // Custom group avatars aren't shipped yet (see OnymGroupAvatar /
        // ChatGroup notes), so no camera badge — the badge implied a
        // tappable upload affordance that didn't exist.
        OnymGroupAvatar(size: 92, accent: accentColor)
            .padding(.top, 10)
            .padding(.bottom, 18)
    }

    private var nameField: some View {
        HStack {
            TextField(
                "",
                text: $flow.name,
                prompt: Text(flow.generatedName).foregroundColor(OnymTokens.text3)
            )
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(OnymTokens.text)
                .tint(accentColor)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .onChange(of: nameFocused) { _, isFocused in
                    if isFocused { flow.tappedNameFieldFocused() }
                }
                .onChange(of: flow.name) { _, new in
                    if new.count > 32 { flow.name = String(new.prefix(32)) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var nameFootnote: some View {
        Text("Visible to members. You can change this anytime.")
            .font(.system(size: 11.5))
            .foregroundStyle(OnymTokens.text3)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accentRow: some View {
        HStack(spacing: 12) {
            ForEach(OnymAccent.allCases) { a in
                Button {
                    flow.accent = a
                } label: {
                    ZStack {
                        Circle().fill(a.color)
                        if flow.accent == a {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .scaleEffect(flow.accent == a ? 1.05 : 1)
                    .overlay(
                        Circle()
                            .stroke(a.color, lineWidth: flow.accent == a ? 2 : 0)
                            .padding(-3)
                    )
                    .overlay(
                        Circle()
                            .stroke(OnymTokens.bg, lineWidth: flow.accent == a ? 2 : 0)
                            .padding(-1)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var governancePicker: some View {
        HStack(spacing: 10) {
            ForEach(OnymUIGovernance.allCases) { g in
                governanceCard(g)
            }
        }
    }

    private func governanceCard(_ g: OnymUIGovernance) -> some View {
        let selected = flow.governance == g && g.isAvailable
        let available = g.isAvailable
        return Button {
            guard available else { return }
            flow.governance = g
        } label: {
            governanceCardLabel(g, selected: selected, available: available)
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private func governanceCardLabel(
        _ g: OnymUIGovernance,
        selected: Bool,
        available: Bool
    ) -> some View {
        let labelColor: Color = selected
            ? accentColor
            : (available ? OnymTokens.text : OnymTokens.text2)
        let bgTint: Color = selected ? accentColor.opacity(0.18) : .clear
        let strokeColor: Color = selected ? accentColor : OnymTokens.hairline
        let strokeWidth: CGFloat = selected ? 1.5 : 1
        let shadowColor: Color = selected ? accentColor.opacity(0.14) : .clear

        return VStack(spacing: 8) {
            governanceCardIconBlock(g, selected: selected, available: available)
            Text(g.label)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.13)
                .foregroundStyle(labelColor)
            Text(g.sub)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OnymTokens.text2)
                .padding(.top, -4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(.horizontal, 10)
        .background(bgTint)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: shadowColor, radius: 4)
        .opacity(available ? 1 : 0.55)
    }

    private func governanceCardIconBlock(
        _ g: OnymUIGovernance,
        selected: Bool,
        available: Bool
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            OnymGovIcon(
                type: g,
                accent: selected ? accentColor : OnymTokens.text,
                size: 42,
                dimmed: !selected || !available
            )
            .frame(maxWidth: .infinity, alignment: .center)

            if !available {
                Text("Soon")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(OnymTokens.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OnymTokens.surface3)
                    .clipShape(Capsule())
                    .offset(x: 6, y: -4)
            }

            if selected {
                ZStack {
                    Circle().fill(accentColor)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(OnymTokens.onAccent)
                }
                .frame(width: 18, height: 18)
                .offset(x: 6, y: -4)
            }
        }
    }

    private var selectedExplanation: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(accentColor.opacity(0.85))
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 0) {
                (
                    Text("\(flow.governance.sub). ")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(OnymTokens.text)
                    + Text(flow.governance.tooltip)
                        .font(.system(size: 13))
                        .foregroundColor(OnymTokens.text2)
                )
                .lineSpacing(1.5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(accentColor.opacity(0.08))
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accentColor.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 12)
    }

    private var encryptedFooterCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnymTokens.text2)
            (
                Text("End-to-end encrypted").foregroundColor(OnymTokens.text)
                + Text(" \u{00B7} published on Stellar so anyone can verify it\u{2019}s real.")
                    .foregroundColor(OnymTokens.text2)
            )
            .font(.system(size: 12.5))
            .lineSpacing(1.4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OnymTokens.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 18)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            OnymPrimaryButton(
                title: flow.canAdvanceToStep2 ? "Next \u{00B7} Add people" : "Name your group to continue",
                enabled: flow.canAdvanceToStep2,
                accent: accentColor,
                action: flow.tappedNext
            )
            OnymQuietButton(title: "Cancel", action: flow.onClose)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(OnymTokens.bg)
        .overlay(Rectangle().fill(OnymTokens.hairline).frame(height: 1), alignment: .top)
    }
}

// MARK: - Step 2: review invitees + create

private struct CreateGroupStep2View: View {
    @Bindable var flow: CreateGroupFlow

    var body: some View {
        VStack(spacing: 0) {
            OnymNavTitle(title: "Add People", subtitle: "Step 2 of 2")
            ScrollView {
                VStack(spacing: 0) {
                    typeBanner
                        .padding(.top, 4)
                    if flow.invitees.isEmpty {
                        emptyState
                    } else {
                        inviteesList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            footer
        }
    }

    private var accentColor: Color { flow.accent.color }

    private var typeBanner: some View {
        HStack(spacing: 10) {
            OnymGovIcon(type: flow.governance, accent: accentColor, size: 28)
            (
                Text("\(flow.governance.label). ")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(OnymTokens.text)
                + Text(typeBannerSub)
                    .font(.system(size: 12.5))
                    .foregroundColor(OnymTokens.text2)
            )
            .lineSpacing(1.35)
            Spacer(minLength: 0)
            Text("\(flow.invitees.count)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OnymTokens.surface3)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(accentColor.opacity(0.10))
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accentColor.opacity(0.20), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(OnymTokens.text3)
                .padding(.top, 28)
            Text(emptyStateTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(emptyStateSubtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }

    private var emptyStateTitle: String {
        switch flow.governance {
        case .oneOnOne: "Add the other person"
        case .tyranny, .anarchy: "No invitees yet"
        }
    }

    private var emptyStateSubtitle: String {
        switch flow.governance {
        case .oneOnOne:
            "Paste their inbox key below to start a private dialog."
        case .tyranny, .anarchy:
            "Use \u{201C}Invite by inbox key\u{201D} below to add someone."
        }
    }

    private var typeBannerSub: String {
        switch flow.governance {
        case .oneOnOne: "Just the two of you. No one else can join."
        case .tyranny: "You\u{2019}ll be the only admin."
        case .anarchy: "Everyone has equal control."
        }
    }

    private var inviteesList: some View {
        VStack(spacing: 0) {
            ForEach(Array(flow.invitees.enumerated()), id: \.element.id) { index, invitee in
                inviteeRow(invitee, index: index)
                if index < flow.invitees.count - 1 {
                    Rectangle().fill(OnymTokens.hairline).frame(height: 1)
                }
            }
        }
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 14)
    }

    private func inviteeRow(_ invitee: OnymInvitee, index: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(OnymTokens.surface3)
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("Inbox \(invitee.displayLabel)")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Direct inbox key")
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            }
            .lineLimit(1)
            .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                flow.removeInvitee(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(OnymTokens.text3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if flow.canAddMoreInvitees {
                Button(action: flow.tappedInviteByKey) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(accentColor.opacity(0.22))
                            Image(systemName: "key.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(accentColor)
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Invite by inbox key")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(OnymTokens.text)
                            Text("Paste a 64-char key")
                                .font(.system(size: 11.5))
                                .foregroundStyle(OnymTokens.text2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(OnymTokens.surface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(OnymTokens.hairlineStrong, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            OnymPrimaryButton(
                title: flow.createCTALabel,
                enabled: flow.canCreate,
                accent: accentColor,
                action: flow.tappedCreate
            )

            OnymQuietButton(title: "Back", action: flow.tappedBackFromStep2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(OnymTokens.bg)
        .overlay(Rectangle().fill(OnymTokens.hairline).frame(height: 1), alignment: .top)
    }
}

// MARK: - Invite by inbox key

private struct CreateGroupInviteByKeyView: View {
    @Bindable var flow: CreateGroupFlow
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            OnymNavTitle(
                title: "Invite by Inbox Key",
                subtitle: "For \(flow.name.isEmpty ? "group" : flow.name)"
            )
            ScrollView {
                VStack(spacing: 0) {
                    explanation
                    keyInput
                    if let err = flow.inviteeError {
                        errorPill(err)
                    }
                    pasteButton
                    helper
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            footer
        }
        .onAppear { fieldFocused = true }
    }

    private var accentColor: Color { flow.accent.color }

    private var explanation: some View {
        (
            Text("Ask for their ").foregroundColor(OnymTokens.text2)
            + Text("inbox key").font(.system(size: 13, weight: .semibold)).foregroundColor(OnymTokens.text)
            + Text(" \u{2014} they can find it in ").foregroundColor(OnymTokens.text2)
            + Text("Settings \u{2192} Advanced").font(.system(size: 13, weight: .semibold)).foregroundColor(OnymTokens.text)
            + Text(", or share a QR code from there.").foregroundColor(OnymTokens.text2)
        )
        .font(.system(size: 13))
        .lineSpacing(1.5)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyInput: some View {
        let cleanedLength = flow.inviteeInputCleanedLength
        let isValid = flow.inviteeInputIsValid
        let tooLong = cleanedLength > 64
        let borderColor: Color = {
            if flow.inviteeError != nil { return OnymTokens.red }
            if isValid { return accentColor.opacity(0.5) }
            return OnymTokens.hairline
        }()

        return VStack(alignment: .leading, spacing: 8) {
            TextField(
                "",
                text: $flow.inviteeInput,
                prompt: Text("Paste 64-char inbox key").foregroundColor(OnymTokens.text3),
                axis: .vertical
            )
            .lineLimit(3, reservesSpace: true)
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(OnymTokens.text)
            .tint(accentColor)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($fieldFocused)
            .onChange(of: flow.inviteeInput) { _, _ in
                flow.inviteeError = nil
            }

            Rectangle().fill(OnymTokens.hairline).frame(height: 1)

            HStack {
                Text("\(cleanedLength)/64")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tooLong ? OnymTokens.red : (isValid ? accentColor : OnymTokens.text3))
                Spacer()
                if cleanedLength > 0 {
                    Button {
                        flow.inviteeInput = ""
                        flow.inviteeError = nil
                    } label: {
                        Text("Clear")
                            .font(.system(size: 12))
                            .foregroundStyle(OnymTokens.text2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func errorPill(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12.5))
            .foregroundStyle(OnymTokens.red)
            .lineSpacing(1.4)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OnymTokens.red.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(OnymTokens.red.opacity(0.30), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.top, 10)
    }

    private var pasteButton: some View {
        Button {
            #if canImport(UIKit)
            if let pasted = UIPasteboard.general.string {
                flow.inviteeInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                flow.inviteeError = nil
            }
            #endif
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                Text("Paste from clipboard")
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(accentColor)
            .background(OnymTokens.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(OnymTokens.hairlineStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }

    private var helper: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(OnymTokens.surface3)
                Text("i")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OnymTokens.text2)
            }
            .frame(width: 18, height: 18)
            .padding(.top, 1)

            (
                Text("Don\u{2019}t have their key? ").foregroundColor(OnymTokens.text)
                + Text("Create the group, then share the invite link \u{2014} they can join later without sharing any keys.").foregroundColor(OnymTokens.text2)
            )
            .font(.system(size: 12))
            .lineSpacing(1.5)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OnymTokens.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.top, 16)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            OnymPrimaryButton(
                title: flow.inviteeInputIsValid
                    ? "Add to group"
                    : (flow.inviteeInputCleanedLength == 0 ? "Paste a key to continue" : "Key incomplete"),
                enabled: flow.inviteeInputIsValid,
                accent: accentColor,
                action: flow.tappedAddInvitee
            )
            OnymQuietButton(title: "Cancel", action: flow.tappedCancelInviteByKey)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(OnymTokens.bg)
        .overlay(Rectangle().fill(OnymTokens.hairline).frame(height: 1), alignment: .top)
    }
}

// MARK: - Creating (progress)

private struct CreateGroupCreatingView: View {
    @Bindable var flow: CreateGroupFlow

    var body: some View {
        VStack(spacing: 0) {
            Text("Creating \(flow.name.isEmpty ? "Group" : flow.name)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

            OnymGroupAvatar(
                size: 92,
                accent: flow.accent.color,
                ringPulse: true,
                spinning: true,
                brand: true
            )
            .padding(.top, 24)
            .padding(.bottom, 22)

            stepsCard

            if let error = flow.error {
                errorBanner(error)
                    .padding(.top, 12)
            } else {
                Text("This usually takes a few seconds. It\u{2019}s safe to close this \u{2014} we\u{2019}ll finish in the background.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text3)
                    .lineSpacing(1.45)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var stepsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 {
                    Rectangle().fill(OnymTokens.hairline).frame(height: 1)
                }
                stepRow(step, status: status(for: i))
            }
        }
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func stepRow(_ step: CreateGroupCreatingStep, status: StepStatus) -> some View {
        HStack(spacing: 12) {
            ZStack {
                switch status {
                case .done:
                    Circle().fill(OnymTokens.green)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(OnymTokens.onAccent)
                case .active:
                    Circle()
                        .stroke(flow.accent.color, lineWidth: 2)
                        .opacity(0.25)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(flow.accent.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(activeRotation))
                        .onAppear {
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                                activeRotation = 360
                            }
                        }
                case .pending:
                    Circle().stroke(OnymTokens.hairlineStrong, lineWidth: 2)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text(step.sub)
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(status == .pending ? 0.5 : 1)
    }

    @State private var activeRotation: Double = 0

    private func errorBanner(_ error: CreateGroupError) -> some View {
        VStack(spacing: 12) {
            // Soroban diagnostic chains can be 500+ chars; keep the
            // banner from eating the whole screen. ScrollView caps the
            // height; .textSelection(.enabled) lets the user copy the
            // error for bug reports.
            ScrollView(.vertical, showsIndicators: true) {
                Text(error.localizedDescription)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OnymTokens.red)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .frame(maxHeight: 200)

            HStack(spacing: 10) {
                Button {
                    flow.tappedCancelFromError()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(OnymTokens.text2)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(OnymTokens.surface3)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    flow.tappedDismissError()
                } label: {
                    Text("Try again")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(flow.accent.color)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(OnymTokens.surface2)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(OnymTokens.red.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(OnymTokens.red.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Step plan

    private var steps: [CreateGroupCreatingStep] {
        var rows: [CreateGroupCreatingStep] = [
            .init(label: "Setting up encrypted group", sub: "Generating keys on your device"),
            .init(label: "Setting up your admin keys", sub: "You\u{2019}ll be the only admin"),
        ]
        for invitee in flow.invitees {
            rows.append(.init(
                label: "Sending invitation to \(invitee.displayLabel)",
                sub: "Encrypted, end-to-end"
            ))
        }
        rows.append(.init(label: "Anchoring on Stellar", sub: "So anyone can verify this group is real"))
        return rows
    }

    private func status(for index: Int) -> StepStatus {
        guard let progress = flow.progress else {
            // No progress means either pre-flight (validating, but we
            // shouldn't be here without progress) OR completed —
            // every step done.
            return flow.error == nil ? .done : .pending
        }
        let activeIndex = currentStepIndex(progress)
        if index < activeIndex { return .done }
        if index == activeIndex { return .active }
        return .pending
    }

    /// Map `CreateGroupProgress` to which row in the steps array is
    /// currently spinning. Validating + Proving share row 0/1; the
    /// real ~3.5s of work is the Tyranny prove call so step 1
    /// dominates wall-clock.
    private func currentStepIndex(_ progress: CreateGroupProgress) -> Int {
        switch progress {
        case .validating: return 0
        case .proving: return 1
        case .anchoring:
            // Anchoring is the last step (after invitations).
            return 2 + flow.invitees.count
        case .sendingInvitations:
            // First invitee row is index 2.
            return 2
        }
    }

    private enum StepStatus { case done, active, pending }
}

private struct CreateGroupCreatingStep {
    let label: String
    let sub: String
}

// MARK: - Success

private struct CreateGroupSuccessView: View {
    @Bindable var flow: CreateGroupFlow

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    membersCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            footer
        }
    }

    private var accentColor: Color { flow.accent.color }
    private var groupName: String {
        flow.createdGroup?.name ?? (flow.name.isEmpty ? "Group" : flow.name)
    }

    private var topBar: some View {
        HStack {
            Spacer().frame(width: 60)
            Spacer()
            Text("\(groupName) is live")
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
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                OnymGroupAvatar(size: 96, accent: accentColor)
                ZStack {
                    Circle().fill(OnymTokens.green)
                        .overlay(Circle().stroke(OnymTokens.bg, lineWidth: 2))
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OnymTokens.onAccent)
                }
                .frame(width: 28, height: 28)
                .offset(x: 4, y: 4)
            }
            .padding(.top, 14)

            Text(groupName)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.22)
                .foregroundStyle(OnymTokens.text)
                .padding(.top, 14)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("End-to-end encrypted")
                    .font(.system(size: 12.5))
            }
            .foregroundStyle(OnymTokens.text2)
            .padding(.top, 4)

            // Type chip
            HStack(spacing: 8) {
                OnymGovIcon(type: flow.governance, accent: accentColor, size: 20)
                (
                    Text("\(flow.governance.label) \u{00B7} ").foregroundColor(OnymTokens.text).font(.system(size: 12.5, weight: .semibold))
                    + Text(typeChipSummary).foregroundColor(OnymTokens.text2).font(.system(size: 12.5))
                )
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.18))
            .background(OnymTokens.surface2)
            .overlay(
                Capsule().stroke(accentColor.opacity(0.30), lineWidth: 1)
            )
            .clipShape(Capsule())
            .padding(.top, 12)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Published on-chain")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(OnymTokens.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(OnymTokens.green.opacity(0.12))
            .clipShape(Capsule())
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }

    private var typeChipSummary: String {
        let n = flow.invitees.count
        return "You\u{2019}re the only admin. \(n) member\(n == 1 ? "" : "s") added."
    }

    private var membersCard: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Members")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    Text("\(flow.invitees.count + 1) \(flow.invitees.count == 0 ? "person" : "people") so far")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnymTokens.text2)
                }
                Spacer()
                Text("You \u{00B7} admin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.18))
                    .background(OnymTokens.surface3)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(Rectangle().fill(OnymTokens.hairline).frame(height: 1), alignment: .bottom)

            // You row
            memberRow(
                badge: "ME",
                badgeColor: accentColor,
                name: "You",
                sub: "Admin \u{00B7} created this group",
                trailing: "Admin"
            )

            // Invitee rows
            ForEach(Array(flow.invitees.enumerated()), id: \.element.id) { index, invitee in
                Rectangle().fill(OnymTokens.hairline).frame(height: 1)
                memberRow(
                    badge: "I\(index + 1)",
                    badgeColor: OnymTokens.surface3,
                    name: "Inbox \(invitee.displayLabel)",
                    sub: "Invited",
                    trailing: nil
                )
            }
        }
        .background(OnymTokens.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 18).stroke(OnymTokens.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func memberRow(
        badge: String,
        badgeColor: Color,
        name: String,
        sub: String,
        trailing: String?
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(badgeColor)
                Text(badge)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.text2)
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            // Level-2 deeplink invite (PR-5 of the deeplink stack).
            // Only enabled once the group is persisted on chain — the
            // invite-link mint side-effect needs a real `groupID` and
            // an active identity.
            OnymPrimaryButton(
                title: "Share invite link",
                enabled: flow.createdGroup != nil,
                accent: accentColor,
                action: flow.tappedShareInvite
            )
            .accessibilityIdentifier("create_group.share_invite_button")
            Button(action: flow.tappedDone) {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnymTokens.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .accessibilityIdentifier("create_group.done_button")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 22)
        .background(OnymTokens.bg)
        .overlay(Rectangle().fill(OnymTokens.hairline).frame(height: 1), alignment: .top)
    }
}
