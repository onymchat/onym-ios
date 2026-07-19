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
    @State private var renameTarget: IdentitySummary?
    @State private var showRestore = false
    /// Carousel height = the tallest page's intrinsic content height (a
    /// paged TabView won't self-size, so pages report their height via
    /// `CarouselHeightKey` and we take the max).
    @State private var carouselHeight: CGFloat = 300
    @FocusState private var addNameFocused: Bool

    /// Transparent probe that reports its page's content height so the
    /// carousel can size to the tallest page (see `carouselHeight`).
    private var carouselHeightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CarouselHeightKey.self, value: proxy.size.height)
        }
    }

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
            // Built-in `.page` dots float at the bottom of the TabView
            // frame, overlapping the shorter add-page content (the Create
            // button). Hide them and draw our own row below the carousel.
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: carouselHeight)
            .onPreferenceChange(CarouselHeightKey.self) { height in
                // Grow only, to the tallest page ever measured. Monotonic so
                // swiping between pages of different content never shrinks the
                // frame back (no per-swipe height jump).
                if height > carouselHeight { carouselHeight = height }
            }
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

            pageIndicator
        }
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .sheet(item: removalBinding) { summary in
            RemoveIdentitySheet(flow: flow, summary: summary)
        }
        .sheet(item: $renameTarget) { summary in
            RenameIdentitySheet(flow: flow, summary: summary)
        }
        .sheet(isPresented: $showRestore) {
            RestoreIdentitySheet(flow: flow)
        }
    }

    // MARK: - Page indicator

    /// Total pages = every identity + the trailing add page.
    private var pageCount: Int { flow.identities.count + 1 }

    /// Index of the currently-shown page (add page is last).
    private var currentIndex: Int {
        if selection == Self.addTag { return flow.identities.count }
        return flow.identities.firstIndex { $0.id.rawValue.uuidString == selection } ?? 0
    }

    /// Custom dot row rendered below the carousel so it never overlaps a
    /// page's own controls.
    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< pageCount, id: \.self) { i in
                Circle()
                    .fill(i == currentIndex
                          ? OnymAccent.blue.color
                          : OnymTokens.text3.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentIndex)
        .padding(.top, 2)
        .padding(.bottom, 14)
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
                Button {
                    renameTarget = summary
                } label: {
                    HStack(spacing: 5) {
                        Text(summary.name)
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.2)
                            .foregroundStyle(isActive ? OnymAccent.blue.color : OnymTokens.text)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnymTokens.text3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("identity.rename.\(summary.id.rawValue.uuidString)")
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
                Text("Start a chat by scanning")
                    .font(.system(size: 11))
                    .foregroundStyle(OnymTokens.text2)
                    .padding(.top, 2)
                Text("BLS \(flow.blsPrefix(of: summary))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OnymTokens.text3)
                    .multilineTextAlignment(.center)
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
        // Measure the natural content height first, then fill the carousel
        // frame so every page occupies the same area (uniform swipe surface).
        .background(carouselHeightReader)
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
                SettingsQRCode(value: "onym-add-identity", size: 140)
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

            Button {
                addNameFocused = false
                showRestore = true
            } label: {
                Text("Restore from recovery phrase")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnymAccent.blue.color)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityIdentifier("identity.add.restore_button")

            if let error = flow.addError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OnymTokens.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        // Measure the natural content height first, then fill the carousel
        // frame so every page occupies the same area (uniform swipe surface).
        .background(carouselHeightReader)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Rename sheet reached by tapping an identity's alias in the carousel.
/// A rename is a local, display-only change — it never touches the keys or
/// the invite link. Prefilled with the current name; empty input is a no-op.
struct RenameIdentitySheet: View {
    @Bindable var flow: IdentitiesFlow
    let summary: IdentitySummary
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    /// Cap matches the inline editor / Android (`MAX_IDENTITY_NAME_LENGTH`).
    private static let maxLength = 30

    init(flow: IdentitiesFlow, summary: IdentitySummary) {
        self.flow = flow
        self.summary = summary
        _text = State(initialValue: summary.name)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSave: Bool { !trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("A name only you see. It doesn't change your keys or your invite link.")
                        .font(.callout)
                        .foregroundStyle(OnymTokens.text2)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    SettingsCard {
                        TextField("Identity name", text: $text)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .font(.system(size: 16.5))
                            .submitLabel(.done)
                            .onSubmit(save)
                            .onChange(of: text) { _, newValue in
                                if newValue.count > Self.maxLength {
                                    text = String(newValue.prefix(Self.maxLength))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("rename_identity.name_field")
                    }

                    Button(action: save) {
                        Text("Save")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(OnymAccent.blue.color,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .accessibilityIdentifier("rename_identity.save_button")
                }
                .padding(.bottom, 24)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle("Rename Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() {
        guard canSave else { return }
        flow.rename(summary.id, newName: trimmed)
        dismiss()
    }
}

/// Restore an existing identity from its 12/24-word recovery phrase.
/// Reached from the carousel's add page. The backing add pipeline
/// (`IdentitiesFlow.submitAdd` → `repository.add(mnemonic:)`) already
/// supports restore + invalid-phrase errors; this is its UI surface.
struct RestoreIdentitySheet: View {
    @Bindable var flow: IdentitiesFlow
    @Environment(\.dismiss) private var dismiss

    @State private var phrase = ""
    @State private var name = ""
    /// Identity count when the sheet opened — used to detect a
    /// successful restore (the list grows) and dismiss.
    @State private var baselineCount = 0

    private var words: [String] {
        phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    private var canRestore: Bool { words.count == 12 || words.count == 24 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enter the 12 or 24-word recovery phrase to restore an identity on this device.")
                        .font(.callout)
                        .foregroundStyle(OnymTokens.text2)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    SettingsCard {
                        TextField("word word word …", text: $phrase, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 16, design: .monospaced))
                            .lineLimit(3...6)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("restore_identity.phrase_field")
                    }

                    SettingsCard {
                        TextField("Name (optional)", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .font(.system(size: 16.5))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("restore_identity.name_field")
                    }

                    if let error = flow.addError {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(OnymTokens.red)
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("restore_identity.error")
                    }

                    Button(action: restore) {
                        Text("Restore")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(OnymAccent.blue.color,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRestore)
                    .opacity(canRestore ? 1 : 0.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .accessibilityIdentifier("restore_identity.restore_button")
                }
                .padding(.bottom, 24)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle("Restore Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                baselineCount = flow.identities.count
                flow.addError = nil
            }
            .onChange(of: flow.identities.count) { _, newValue in
                // A successful restore appends the identity — dismiss.
                if newValue > baselineCount { dismiss() }
            }
        }
    }

    private func restore() {
        guard canRestore else { return }
        flow.addError = nil
        flow.pendingName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        flow.pendingMnemonic = words.joined(separator: " ")
        flow.submitAdd()
    }
}

/// Collects the tallest carousel page's content height so the paged
/// `TabView` (which won't self-size) can be framed to its intrinsic max.
private struct CarouselHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
