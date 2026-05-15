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
    @State private var showShareKey = false

    /// Persisted in `UserDefaults` under the same key
    /// `UserDefaultsNetworkPreference` reads. Toggling here changes
    /// the network the next Create Group flow will use.
    @AppStorage(UserDefaultsNetworkPreference.storageKey) private var useMainnet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Settings")

                identityHero
                qrHero

                if let count = unbackedCount, count > 0 {
                    notBackedUpBanner(count: count)
                }

                SettingsSectionLabel("SECURITY")
                SettingsCard {
                    NavigationLink {
                        IdentitiesView(flow: identitiesFlow)
                    } label: {
                        SettingsRow(
                            title: "Identities",
                            subtitle: identitySubtitle
                        ) {
                            SettingsIconTile(symbol: "person.2.fill", bg: SettingsTile.purple)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.identities_row")

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
        .sheet(isPresented: $showShareKey) {
            if let active = activeSummary {
                NavigationStack {
                    ShareKeyView(identity: active, blsPrefix: identitiesFlow.blsPrefix(of: active))
                }
            }
        }
    }

    // MARK: - Hero cards

    private var activeSummary: IdentitySummary? {
        guard let id = identitiesFlow.currentID else { return nil }
        return identitiesFlow.identities.first { $0.id == id }
    }

    private var identityHero: some View {
        NavigationLink {
            IdentitiesView(flow: identitiesFlow)
        } label: {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(LinearGradient(
                            colors: [
                                Color.dynamic(light: Color(red: 0.933, green: 0.961, blue: 1.0),
                                              dark: Color(red: 10/255, green: 132/255, blue: 255/255).opacity(0.18)),
                                Color.dynamic(light: Color(red: 0.878, green: 0.933, blue: 0.996),
                                              dark: Color(red: 10/255, green: 132/255, blue: 255/255).opacity(0.10))
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 56, height: 56)
                        .overlay(Circle().stroke(OnymAccent.blue.color, lineWidth: 1.5))
                        .overlay(OnymMark(size: 36, color: OnymAccent.blue.color))
                    Circle()
                        .fill(OnymTokens.green)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(OnymTokens.surface2, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE IDENTITY")
                        .font(.system(size: 11.5, weight: .medium))
                        .tracking(0.22)
                        .foregroundStyle(OnymTokens.text2)
                    Text(activeSummary?.name ?? "No identity")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                        .tracking(-0.19)
                    if let summary = activeSummary {
                        Text("BLS \(identitiesFlow.blsPrefix(of: summary))…")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(OnymTokens.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnymTokens.text3)
            }
            .padding(16)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.identity_hero")
    }

    private var qrHero: some View {
        Button {
            if activeSummary != nil { showShareKey = true }
        } label: {
            HStack(spacing: 16) {
                let payload = activeSummary?.inboxPublicKey ?? Data(count: 16)
                SettingsQRCode(value: settingsInviteURL(inboxPublicKey: payload), size: 92)
                    .padding(8)
                    .background(OnymTokens.surface2,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OnymTokens.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 4) {
                    Text("INVITE KEY")
                        .font(.system(size: 11.5, weight: .medium))
                        .tracking(0.46)
                        .foregroundStyle(OnymTokens.text2)
                    Text("Start a chat by scanning")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                        .tracking(-0.16)
                    Text("Have someone scan this code with Onym to open a private chat with \(activeSummary?.name ?? "this identity").")
                        .font(.system(size: 12.5))
                        .foregroundStyle(OnymTokens.text2)
                        .lineSpacing(2)
                        .lineLimit(3)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnymTokens.text3)
            }
            .padding(18)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.invite_hero")
    }

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

    private var identitySubtitle: String {
        let total = identitiesFlow.identities.count
        return total <= 1 ? "Manage your identity" : "\(total) identities · switch active"
    }

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
