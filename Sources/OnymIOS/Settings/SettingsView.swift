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
    let makeBlossomRelaySettingsFlow: @MainActor () -> BlossomRelaySettingsFlow
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow
    let identitiesFlow: IdentitiesFlow
    /// Wipes every local message (keeps chats). Wired to
    /// `MessageRepository.removeAll`. Runs behind a two-step confirm.
    let onClearAllMessages: () async -> Void

    @State private var showRecoveryPhrase = false
    /// The identity whose invite-key share view is presented, if any.
    @State private var shareIdentity: IdentitySummary?

    /// First / second gate of the "clear message cache" double-confirm.
    @State private var showClearConfirm1 = false
    @State private var showClearConfirm2 = false

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
                IdentityCarouselCard(
                    flow: identitiesFlow,
                    onBackup: { showRecoveryPhrase = true },
                    onShare: { shareIdentity = $0 }
                )
                .padding(.bottom, 4)

                if let count = unbackedCount, count > 0 {
                    notBackedUpBanner(count: count)
                }

                // The SECURITY section (Privacy & Encryption + Backup
                // Recovery Phrase) was removed: recovery-phrase backup now
                // lives on each identity's carousel page (its Backup
                // action), and the informational Privacy screen is gone.

                SettingsSectionLabel("ANCHORS")
                SettingsCard {
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

                    // The network choice (was a "Use Mainnet" toggle) now
                    // lives inside the Anchors screen as the active-network
                    // selector — the subtitle above reflects it.

                    NavigationLink {
                        RelayerSettingsView(flow: makeRelayerSettingsFlow())
                    } label: {
                        SettingsRow(
                            title: "Relayer",
                            subtitle: "Stellar Soroban",
                            last: true
                        ) {
                            SettingsIconTile(symbol: "antenna.radiowaves.left.and.right",
                                             bg: SettingsTile.indigo)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.relayer_row")
                }
                SettingsFootnote("Anchors and the relayer default to Onym-run instances. Replace them with your own deployments for maximum privacy.")

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

                    NavigationLink {
                        BlossomRelaySettingsView(flow: makeBlossomRelaySettingsFlow())
                    } label: {
                        SettingsRow(
                            title: "Blossom Relays",
                            subtitle: "Media storage servers",
                            last: true
                        ) {
                            SettingsIconTile(
                                symbol: "photo.on.rectangle.angled",
                                bg: SettingsTile.indigo
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.blossom_relays_row")
                }
                SettingsFootnote("Nostr relays and Blossom servers carry your messages and media. Replace them with your own instances for maximum privacy.")

                SettingsSectionLabel("DATA")
                SettingsCard {
                    SettingsRow(
                        title: "Send read receipts",
                        subtitle: "You'll only see others' read status if this is on",
                        subtitleLineLimit: nil,
                        hasChevron: false
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

                    Button { showClearConfirm1 = true } label: {
                        SettingsRow(
                            title: "Clear Local Message Cache",
                            titleColor: OnymTokens.red,
                            subtitle: "Delete every message on this device. Your chats stay.",
                            hasChevron: false,
                            last: true
                        ) {
                            SettingsIconTile(symbol: "trash.fill", bg: SettingsTile.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.clear_messages_row")
                }
                SettingsFootnote("Onym keeps no copy of your messages on any server — this device is the only place they live. Cleared messages can’t be downloaded again: relays hold them only briefly and may already have dropped them.")

                watermark
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        // Use the system large-title bar so the title collapses to inline
        // and content scrolls under a translucent bar (scroll-edge effect),
        // matching standard iOS navigation behavior.
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task { await identitiesFlow.start() }
        .sheet(isPresented: $showRecoveryPhrase) {
            RecoveryPhraseBackupView(flow: makeBackupFlow())
        }
        .sheet(item: $shareIdentity) { summary in
            NavigationStack {
                ShareKeyView(identity: summary, blsPrefix: identitiesFlow.blsPrefix(of: summary))
            }
        }
        // Double confirmation: the first alert explains what's lost and
        // that it can't be re-downloaded; the second is a final are-you-sure.
        .alert("Clear all messages?", isPresented: $showClearConfirm1) {
            Button("Clear Messages", role: .destructive) { showClearConfirm2 = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every message stored on this device. Your chats stay in the list, but the messages inside them will be gone.\n\nOnym keeps no copy on its servers, and messages can’t be re-downloaded — relay copies are best-effort and may already have expired.")
        }
        .alert("Delete all messages?", isPresented: $showClearConfirm2) {
            Button("Delete All Messages", role: .destructive) {
                Task { await onClearAllMessages() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
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
        VStack(spacing: 6) {
            OnymMark(size: 26, color: OnymTokens.text3)
                .padding(.top, 28)
            Text("Built by people who think privacy is a right")
                .font(.system(size: 12))
                .foregroundStyle(OnymTokens.text3)
                .multilineTextAlignment(.center)
            Text(aboutSubtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OnymTokens.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
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
