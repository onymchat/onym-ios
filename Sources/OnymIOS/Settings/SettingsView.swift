import SwiftUI

/// Settings tab — Onym design home. Identity hero (active identity
/// avatar + truncated BLS fingerprint) and a per-identity invite QR
/// hero open the multi-identity drill-down. Below them sit the
/// Security / Network / App grouped cards.
///
/// All flow plumbing comes from `AppDependencies` so this view stays a
/// thin shell over the existing `IdentitiesFlow` /
/// `RecoveryPhraseBackupFlow` / `RelayerSettingsFlow` /
/// `AnchorsPickerFlow` machinery — only the pixels change.
struct SettingsView: View {
    let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    let makeRelayerSettingsFlow: @MainActor () -> RelayerSettingsFlow
    let makeNostrRelaySettingsFlow: @MainActor () -> NostrRelaySettingsFlow
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow
    let identitiesFlow: IdentitiesFlow

    @State private var showRecoveryPhrase = false
    /// The identity whose invite-key share view is presented, if any.
    @State private var shareIdentity: IdentitySummary?

    /// Persisted in `UserDefaults` under the same key
    /// `UserDefaultsNetworkPreference` reads. Toggling here changes
    /// the network the next Create Group flow will use.
    @AppStorage(UserDefaultsNetworkPreference.storageKey) private var useMainnet = false

    /// Symmetric read receipts (default ON): gates both sending your
    /// read receipts and seeing others'. Same key as
    /// `ReadReceiptsPreference`.
    @AppStorage(ReadReceiptsPreference.storageKey) private var sendReadReceipts = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Settings")

                IdentityCarouselCard(
                    flow: identitiesFlow,
                    onBackup: { showRecoveryPhrase = true },
                    onShare: { shareIdentity = $0 }
                )
                .padding(.bottom, 4)

                if let count = unbackedCount, count > 0 {
                    notBackedUpBanner(count: count)
                }

                SettingsSectionLabel("SECURITY")
                SettingsCard {
                    NavigationLink {
                        PrivacyEncryptionView(identitiesFlow: identitiesFlow)
                    } label: {
                        SettingsRow(
                            title: "Privacy & Encryption",
                            subtitle: "End-to-end · BIP-39"
                        ) {
                            SettingsIconTile(symbol: "lock.shield.fill", bg: SettingsTile.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.privacy_row")

                    // Permanent backup entry. The `notBackedUpBanner` below
                    // is a soft nudge that only appears when at least one
                    // identity is unbacked; this row is the always-visible
                    // way to reach the recovery-phrase flow.
                    Button { showRecoveryPhrase = true } label: {
                        SettingsRow(
                            title: "Backup Recovery Phrase",
                            subtitle: "12-word BIP-39 phrase",
                            last: true
                        ) {
                            SettingsIconTile(symbol: "key.fill", bg: SettingsTile.amber)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.backup_recovery_phrase_row")
                }

                SettingsSectionLabel("NETWORK")
                SettingsCard {
                    NavigationLink {
                        RelayerSettingsView(flow: makeRelayerSettingsFlow())
                    } label: {
                        SettingsRow(
                            title: "Relayer",
                            subtitle: "Stellar Soroban · onymchat"
                        ) {
                            SettingsIconTile(symbol: "antenna.radiowaves.left.and.right",
                                             bg: SettingsTile.indigo)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.relayer_row")

                    NavigationLink {
                        AnchorsView(flow: makeAnchorsPickerFlow())
                    } label: {
                        SettingsRow(
                            title: "Anchors",
                            subtitle: useMainnet ? "Stellar · Mainnet" : "Stellar · Testnet"
                        ) {
                            SettingsIconTile(symbol: "link", bg: SettingsTile.orange)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.anchors_row")

                    SettingsRow(
                        title: "Use Mainnet",
                        subtitle: "Testnet by default while contracts are staged",
                        hasChevron: false,
                        last: true
                    ) {
                        SettingsIconTile(
                            symbol: useMainnet ? "globe.americas.fill" : "hammer.fill",
                            bg: useMainnet ? SettingsTile.green : SettingsTile.gray
                        )
                    } right: {
                        Toggle("", isOn: $useMainnet)
                            .labelsHidden()
                            .tint(OnymTokens.green)
                            .accessibilityIdentifier("settings.use_mainnet_toggle")
                    }
                }

                SettingsSectionLabel("TRANSPORT")
                SettingsCard {
                    NavigationLink {
                        NostrRelaySettingsView(flow: makeNostrRelaySettingsFlow())
                    } label: {
                        SettingsRow(
                            title: "Nostr Relays",
                            subtitle: "Inbox + invitation transport"
                        ) {
                            SettingsIconTile(
                                symbol: "antenna.radiowaves.left.and.right.circle.fill",
                                bg: SettingsTile.indigo
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.nostr_relays_row")

                    SettingsRow(
                        title: "Tor (Hidden Service)",
                        subtitle: "Coming soon",
                        hasChevron: false,
                        last: true
                    ) {
                        SettingsIconTile(
                            symbol: "shield.lefthalf.filled",
                            bg: SettingsTile.gray
                        )
                    } right: {
                        Text("TBA")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(OnymTokens.text3)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                OnymTokens.surface3,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                    .accessibilityIdentifier("settings.tor_row")
                }

                SettingsSectionLabel("CHAT")
                SettingsCard {
                    SettingsRow(
                        title: "Send read receipts",
                        subtitle: "You'll only see others' read status if this is on",
                        hasChevron: false,
                        last: true
                    ) {
                        SettingsIconTile(
                            symbol: sendReadReceipts ? "checkmark.message.fill" : "message",
                            bg: sendReadReceipts ? SettingsTile.indigo : SettingsTile.gray
                        )
                    } right: {
                        Toggle("", isOn: $sendReadReceipts)
                            .labelsHidden()
                            .tint(OnymTokens.green)
                            .accessibilityIdentifier("settings.read_receipts_toggle")
                    }
                }

                SettingsSectionLabel("APP")
                SettingsCard {
                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingsRow(
                            title: "About Onym",
                            subtitle: aboutSubtitle,
                            last: true
                        ) {
                            SettingsIconTile(symbol: "info.circle.fill", bg: SettingsTile.teal)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.about_row")
                }

                watermark
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await identitiesFlow.start() }
        .sheet(isPresented: $showRecoveryPhrase) {
            RecoveryPhraseBackupView(flow: makeBackupFlow())
        }
        .sheet(item: $shareIdentity) { summary in
            NavigationStack {
                ShareKeyView(identity: summary, blsPrefix: identitiesFlow.blsPrefix(of: summary))
            }
        }
    }

    // MARK: - Hero cards


    private func notBackedUpBanner(count: Int) -> some View {
        Button { showRecoveryPhrase = true } label: {
            HStack(spacing: 10) {
                Circle().fill(SettingsTile.amber).frame(width: 22, height: 22)
                    .overlay(Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white))
                Text(count == 1
                     ? "1 identity hasn’t been backed up yet."
                     : "\(count) identities haven’t been backed up yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.36, green: 0.227, blue: 0))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.36, green: 0.227, blue: 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 1, green: 0.965, blue: 0.898),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(red: 1, green: 0.847, blue: 0.627), lineWidth: 0.5))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.unbacked_banner")
    }

    private var watermark: some View {
        VStack(spacing: 8) {
            OnymMark(size: 26, color: OnymTokens.text3)
                .padding(.top, 28)
            Text("onym · open · anonymous · onchain")
                .font(.system(size: 11))
                .tracking(0.22)
                .foregroundStyle(OnymTokens.text3)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Subtitles

    private var aboutSubtitle: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (build \(b))"
    }

    /// Identities aren’t marked “backed-up” by `IdentitySummary` directly
    /// — the flow is binary on the active identity. We surface the
    /// banner only when the user lacks a recovery phrase entirely; the
    /// dedicated Identity Detail screen lets them back up each one.
    private var unbackedCount: Int? {
        // Always show the banner if there is no identity (e.g. migrating
        // from an older build). Otherwise the design's banner is a
        // soft nudge — return nil to suppress when we can't query the
        // detailed state from this view.
        return nil
    }
}
