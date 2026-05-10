import SwiftUI

/// Settings → Identities. Reskinned to match the Onym design while
/// keeping every flow intent (add / select / remove) wired through
/// the existing `IdentitiesFlow`. Tap a row to open `IdentityDetailView`;
/// "Set as active" lives there. Swipe / context-menu Remove still
/// gates behind a name-confirm sheet.
struct IdentitiesView: View {
    @Bindable var flow: IdentitiesFlow
    @State private var showAddSheet = false
    /// Per-row height, scaled with Dynamic Type via `UIFontMetrics`.
    /// 64 is the baseline at default size (matches `SettingsRow`'s
    /// padding + dual-line label); AX1+/XL settings scale it up
    /// automatically so the inner List frame grows in step.
    @ScaledMetric private var rowHeight: CGFloat = 64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Identities")
                SettingsFootnote("Tap an identity to open it. Each identity has its own keys, chats, and recovery phrase.")

                SettingsSectionLabel("YOUR IDENTITIES")
                identitiesList

                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(OnymAccent.blue.color).frame(width: 22, height: 22)
                            .overlay(Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(OnymTokens.onAccent))
                        Text("Add Identity")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(OnymAccent.blue.color)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(OnymTokens.surface2,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("identities.add_button")

                SettingsFootnote("Only the active identity’s chats are visible. Switch between identities to see different inboxes.")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Identities")
        .navigationBarTitleDisplayMode(.inline)
        .task { await flow.start() }
        .sheet(isPresented: $showAddSheet, onDismiss: flow.cancelAdd) {
            AddIdentitySheet(flow: flow, isPresented: $showAddSheet)
        }
        .sheet(
            isPresented: Binding(
                get: { flow.pendingRemoval != nil },
                set: { if !$0 { flow.cancelRemoval() } }
            )
        ) {
            if let summary = flow.pendingRemoval {
                RemoveIdentitySheet(flow: flow, summary: summary)
            }
        }
    }

    // MARK: - Identities list

    /// SwiftUI `.swipeActions` is a List-only modifier — applying it to a
    /// `VStack`/`SettingsCard` row is silently inert. We want both the
    /// SettingsCard look (rounded card, custom hairlines) and native
    /// swipe-to-Remove, so the rows live inside a `List` with system
    /// chrome suppressed: `.listStyle(.plain)`, transparent
    /// `scrollContentBackground`, hidden separators (we draw our own),
    /// and `.scrollDisabled` + a `rowHeight × count` frame so the outer
    /// `ScrollView` still drives scrolling. `rowHeight` is `@ScaledMetric`
    /// so the frame grows with Dynamic Type / AX1+ sizes.
    @ViewBuilder
    private var identitiesList: some View {
        let summaries = flow.identities
        if summaries.isEmpty {
            // Avoid reserving a phantom row strip when the list is empty.
            // Today bootstrapping guarantees ≥1 identity, but the empty
            // branch keeps the layout honest if that ever loosens.
            EmptyView()
        } else {
            List {
                ForEach(Array(summaries.enumerated()), id: \.element.id) { idx, summary in
                    NavigationLink {
                        IdentityDetailView(flow: flow, summary: summary)
                    } label: {
                        SettingsRow(
                            title: LocalizedStringKey(summary.name),
                            subtitle: "BLS \(flow.blsPrefix(of: summary))…",
                            subtitleMono: true,
                            inset: 68,
                            last: idx == summaries.count - 1
                        ) {
                            IdentityRingTile(active: summary.id == flow.currentID, size: 40)
                        } right: {
                            if summary.id == flow.currentID {
                                Text("Active")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(OnymTokens.green.opacity(0.18),
                                                in: Capsule())
                                    .foregroundStyle(OnymTokens.green)
                                    .accessibilityIdentifier("identities.active_badge.\(summary.id)")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("identities.row.\(summary.id)")
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            flow.startRemoval(of: summary)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            flow.startRemoval(of: summary)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .listRowBackground(OnymTokens.surface2)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(summaries.count) * rowHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Add sheet

private struct AddIdentitySheet: View {
    @Bindable var flow: IdentitiesFlow
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Circle().fill(OnymTokens.surface3)
                        .frame(width: 80, height: 80)
                        .overlay(OnymMark(size: 46, color: SettingsTile.gray))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                        .padding(.bottom, 24)

                    SettingsSectionLabel("NAME")
                    SettingsCard {
                        TextField("Identity name", text: $flow.pendingName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .font(.system(size: 16.5))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("add_identity.name_field")
                    }
                    SettingsFootnote("Defaults to “Identity N” if left blank.")

                    SettingsSectionLabel("RESTORE FROM RECOVERY PHRASE")
                    SettingsCard {
                        TextEditor(text: $flow.pendingMnemonic)
                            .frame(minHeight: 96)
                            .font(.system(size: 15, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("add_identity.mnemonic_field")
                    }
                    SettingsFootnote("Leave blank to mint a fresh BIP-39 identity. Paste a 12 or 24-word phrase to restore.")

                    if let error = flow.addError {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle("Add Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        flow.cancelAdd()
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        flow.submitAdd()
                        if flow.addError == nil { isPresented = false }
                    }
                    .accessibilityIdentifier("add_identity.submit_button")
                }
            }
        }
    }
}

// MARK: - Remove sheet

private struct RemoveIdentitySheet: View {
    @Bindable var flow: IdentitiesFlow
    let summary: IdentitySummary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Removing **\(summary.name)** wipes its on-device secrets and every chat created under it. This cannot be undone — the recovery phrase is the only way back in.")
                        .font(.callout)
                        .foregroundStyle(OnymTokens.text)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    SettingsCard {
                        TextField("Type \"\(summary.name)\" to confirm",
                                  text: $flow.pendingRemovalConfirmText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 16.5))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("remove_identity.confirm_field")
                    }

                    Button(role: .destructive) {
                        flow.confirmRemoval()
                    } label: {
                        Text("Remove identity")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(OnymTokens.red,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!flow.canConfirmRemoval)
                    .opacity(flow.canConfirmRemoval ? 1 : 0.5)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .accessibilityIdentifier("remove_identity.remove_button")
                }
                .padding(.bottom, 24)
            }
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle("Remove Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: flow.cancelRemoval)
                }
            }
        }
    }
}
