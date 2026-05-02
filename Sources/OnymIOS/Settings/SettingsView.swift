import SwiftUI

/// Settings tab — entry point for the recovery-phrase backup flow.
/// Minimal first cut: one Security section with the Backup row that
/// presents `RecoveryPhraseBackupView` as a sheet. More sections land
/// as the app grows (preferences, advanced, about).
struct SettingsView: View {
    let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    let makeRelayerSettingsFlow: @MainActor () -> RelayerSettingsFlow
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow

    @State private var showRecoveryPhrase = false

    var body: some View {
        Form {
            Section {
                Button {
                    showRecoveryPhrase = true
                } label: {
                    row(
                        icon: SettingsIconBox(systemImage: "key.fill", background: .orange),
                        title: "Backup Recovery Phrase"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.backup_recovery_phrase_row")
            } header: {
                Text("Security")
            } footer: {
                Text("View your 12-word recovery phrase. You will need it to restore your identity on a new device.")
            }

            Section {
                NavigationLink {
                    RelayerSettingsView(flow: makeRelayerSettingsFlow())
                } label: {
                    row(
                        icon: SettingsIconBox(systemImage: "antenna.radiowaves.left.and.right", background: .blue),
                        title: "Relayer"
                    )
                }
                .accessibilityIdentifier("settings.relayer_row")

                NavigationLink {
                    AnchorsView(flow: makeAnchorsPickerFlow())
                } label: {
                    row(
                        icon: SettingsIconBox(systemImage: "link", background: .indigo),
                        title: "Anchors"
                    )
                }
                .accessibilityIdentifier("settings.anchors_row")
            } header: {
                Text("Network")
            } footer: {
                Text("Choose the relayer that submits transactions and which contract version anchors new chats. Existing chats keep the contract they were created with.")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showRecoveryPhrase) {
            RecoveryPhraseBackupView(flow: makeBackupFlow())
        }
    }

    @ViewBuilder
    private func row(icon: SettingsIconBox, title: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            icon
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Coloured rounded-rectangle icon used in `Form` rows. Same visual
/// treatment as the rules list on the recovery-phrase intro screen.
struct SettingsIconBox: View {
    let systemImage: String
    let background: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
                .frame(width: 30, height: 30)
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
