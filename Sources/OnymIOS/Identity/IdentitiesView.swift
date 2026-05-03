import SwiftUI

/// Settings → Identities. Shows every identity with name + BLS
/// fingerprint + an "Active" badge on the currently-selected one.
/// Tap a row to switch identities. Swipe / context-menu Remove gates
/// behind a name-confirm sheet.
struct IdentitiesView: View {
    @Bindable var flow: IdentitiesFlow
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section {
                ForEach(flow.identities, id: \.id) { summary in
                    Button {
                        flow.select(summary.id)
                    } label: {
                        identityRow(summary)
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
                }
            } footer: {
                Text("Tap an identity to make it active. Only the active identity\u{2019}s chats are visible.")
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Identity", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("identities.add_button")
            }
        }
        .navigationTitle("Identities")
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

    @ViewBuilder
    private func identityRow(_ summary: IdentitySummary) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.2))
                Image(systemName: "person.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("BLS \(flow.blsPrefix(of: summary))\u{2026}")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if summary.id == flow.currentID {
                Text("Active")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.18))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
                    .accessibilityIdentifier("identities.active_badge.\(summary.id)")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add sheet

private struct AddIdentitySheet: View {
    @Bindable var flow: IdentitiesFlow
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Identity name", text: $flow.pendingName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("add_identity.name_field")
                } header: {
                    Text("Name")
                } footer: {
                    Text("Defaults to \u{201C}Identity N\u{201D} if left blank.")
                }

                Section {
                    TextEditor(text: $flow.pendingMnemonic)
                        .frame(minHeight: 80)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("add_identity.mnemonic_field")
                } header: {
                    Text("Restore from recovery phrase (optional)")
                } footer: {
                    Text("Leave blank to mint a fresh BIP39 identity. Paste a 12 or 24-word phrase to restore.")
                }

                if let error = flow.addError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
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
                        // Closing the sheet on success is racy with
                        // the async submit; stay open until addError
                        // either populates (failure) or the identity
                        // count grows (success — handled by toolbar
                        // dismissing on a state change in the
                        // identities list).
                        if flow.addError == nil {
                            isPresented = false
                        }
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
            Form {
                Section {
                    Text("Removing **\(summary.name)** wipes its on-device secrets and every chat created under it. This cannot be undone — the recovery phrase is the only way back in.")
                        .font(.callout)
                }
                Section {
                    TextField("Type \"\(summary.name)\" to confirm",
                              text: $flow.pendingRemovalConfirmText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("remove_identity.confirm_field")
                }
                Section {
                    Button(role: .destructive) {
                        flow.confirmRemoval()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Remove identity")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!flow.canConfirmRemoval)
                    .accessibilityIdentifier("remove_identity.remove_button")
                }
            }
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
