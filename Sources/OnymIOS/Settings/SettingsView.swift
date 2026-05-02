import SwiftUI

/// Settings tab — Security + Network sections. The Create Group entry
/// point lives on the Chats tab now (`ChatsView` empty-state CTA +
/// toolbar plus button); Settings is purely configuration.
struct SettingsView: View {
    let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    let makeRelayerSettingsFlow: @MainActor () -> RelayerSettingsFlow
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow

    @State private var showRecoveryPhrase = false

    /// Persisted in `UserDefaults` under the same key
    /// `UserDefaultsNetworkPreference` reads. Toggling here changes the
    /// network the next Create Group flow will use; existing groups
    /// keep whatever network they were created on.
    @AppStorage(UserDefaultsNetworkPreference.storageKey) private var useMainnet = false

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

                Toggle(isOn: $useMainnet) {
                    HStack(spacing: 12) {
                        SettingsIconBox(
                            systemImage: useMainnet ? "globe.americas.fill" : "hammer.fill",
                            background: useMainnet ? .green : .gray
                        )
                        Text("Use Mainnet")
                    }
                }
                .accessibilityIdentifier("settings.use_mainnet_toggle")
            } header: {
                Text("Network")
            } footer: {
                Text(useMainnet
                    ? "New groups will be anchored on Stellar mainnet. Contracts must be deployed and allowlisted on the relayer."
                    : "New groups will be anchored on Stellar testnet. Default while contracts are still being staged."
                )
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
