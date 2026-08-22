import SwiftUI
import OnymDesign
import OnymChain
import OnymIdentity
import OnymIdentityUI
import OnymRecovery
import OnymChatsCore
import OnymModeration
import OnymBackupUI
import OnymModerationUI
import OnymDiscovery

/// Settings tab — Onym design home. Identity hero (active identity
/// avatar + truncated BLS fingerprint) and a per-identity invite QR
/// hero open the multi-identity drill-down. Below them sit the
/// Security / Network / App grouped cards.
///
/// All flow plumbing comes from `AppDependencies` so this view stays a
/// thin shell over the existing `IdentitiesFlow` /
/// `RecoveryPhraseBackupFlow` / `RelayerSettingsFlow` /
/// `AnchorsPickerFlow` machinery — only the pixels change.
public struct SettingsView: View {
    let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    let makeRelayerSettingsFlow: @MainActor () -> RelayerSettingsFlow
    let makeNostrRelaySettingsFlow: @MainActor () -> NostrRelaySettingsFlow
    let makeBlossomRelaySettingsFlow: @MainActor () -> BlossomRelaySettingsFlow
    let makeAnchorsPickerFlow: @MainActor () -> AnchorsPickerFlow
    let identitiesFlow: IdentitiesFlow
    /// Wipes every local message (keeps chats). Wired to
    /// `MessageRepository.removeAll`. Runs behind a two-step confirm.
    let onClearAllMessages: () async -> Void
    /// Moderation drill-down factories. Optional so the Settings
    /// screen renders without the moderation stack (the row is hidden
    /// until the app wires these in).
    let makeModerationSettingsFlow: (@MainActor () -> ModerationSettingsFlow)?
    let makeModerationConsentFlow: (@MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow)?
    let makeModerationCaseFlow: (@MainActor (CaseNotice) -> ModerationCaseFlow)?
    /// Discovery drill-down factory. Optional so the Settings screen
    /// renders without the discovery stack (the section is hidden
    /// until the app wires this in — same pattern as moderation).
    let makeDiscoverySettingsFlow: (@MainActor () -> DiscoverySettingsFlow)?
    /// Settings → Restart Onboarding: re-runs the first-launch seat
    /// selection. KEEPS identity, chats, messages, and every current
    /// choice — the walk just runs again over the applied
    /// configuration. Optional so the row hides when the app runs
    /// without onboarding (UI-test harness) — same pattern as the
    /// moderation/discovery factories. The closure fires only after
    /// the confirmation alert.
    let onRestartOnboarding: (@MainActor () -> Void)?
    /// Settings → Device Backup. Optional so the section hides when the
    /// app has not wired it — same pattern as moderation and discovery.
    ///
    /// Note the name: `makeBackupFlow` above is the *recovery phrase*
    /// backup, which is a different thing entirely. One protects the
    /// key; this protects the history.
    let makeDeviceBackupView: (@MainActor () -> DeviceBackupVendorsView)?
    /// Settings → Backup Operators: the discovery catalog's
    /// `storage.backup` entries, where a backup operator is found and
    /// consented to.
    ///
    /// Separately optional from `makeDeviceBackupView` because the two
    /// appear at different times, and the earlier one is this: until
    /// somebody has consented to an operator there is no Device Backup
    /// screen to build, so a BACKUP section gated on that factory alone
    /// could never be reached from a standing start. The section shows
    /// when EITHER is wired.
    let makeBackupOperatorSettingsFlow: (@MainActor () -> BackupOperatorSettingsFlow)?
    /// Settings → Notifications. Optional so the section hides when
    /// the app runs without the push stack wired — same pattern as
    /// moderation and discovery.
    let makeNotificationsSettingsFlow: (@MainActor () -> NotificationsSettingsFlow)?

    public init(
        makeBackupFlow: @escaping @MainActor () -> RecoveryPhraseBackupFlow,
        makeRelayerSettingsFlow: @escaping @MainActor () -> RelayerSettingsFlow,
        makeNostrRelaySettingsFlow: @escaping @MainActor () -> NostrRelaySettingsFlow,
        makeBlossomRelaySettingsFlow: @escaping @MainActor () -> BlossomRelaySettingsFlow,
        makeAnchorsPickerFlow: @escaping @MainActor () -> AnchorsPickerFlow,
        identitiesFlow: IdentitiesFlow,
        onClearAllMessages: @escaping () async -> Void,
        makeModerationSettingsFlow: (@MainActor () -> ModerationSettingsFlow)? = nil,
        makeModerationConsentFlow: (@MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow)? = nil,
        makeModerationCaseFlow: (@MainActor (CaseNotice) -> ModerationCaseFlow)? = nil,
        makeDiscoverySettingsFlow: (@MainActor () -> DiscoverySettingsFlow)? = nil,
        onRestartOnboarding: (@MainActor () -> Void)? = nil,
        makeDeviceBackupView: (@MainActor () -> DeviceBackupVendorsView)? = nil,
        makeBackupOperatorSettingsFlow: (@MainActor () -> BackupOperatorSettingsFlow)? = nil,
        makeNotificationsSettingsFlow: (@MainActor () -> NotificationsSettingsFlow)? = nil
    ) {
        self.makeBackupFlow = makeBackupFlow
        self.makeRelayerSettingsFlow = makeRelayerSettingsFlow
        self.makeNostrRelaySettingsFlow = makeNostrRelaySettingsFlow
        self.makeBlossomRelaySettingsFlow = makeBlossomRelaySettingsFlow
        self.makeAnchorsPickerFlow = makeAnchorsPickerFlow
        self.identitiesFlow = identitiesFlow
        self.onClearAllMessages = onClearAllMessages
        self.makeModerationSettingsFlow = makeModerationSettingsFlow
        self.makeModerationConsentFlow = makeModerationConsentFlow
        self.makeModerationCaseFlow = makeModerationCaseFlow
        self.makeDiscoverySettingsFlow = makeDiscoverySettingsFlow
        self.onRestartOnboarding = onRestartOnboarding
        self.makeDeviceBackupView = makeDeviceBackupView
        self.makeBackupOperatorSettingsFlow = makeBackupOperatorSettingsFlow
        self.makeNotificationsSettingsFlow = makeNotificationsSettingsFlow
    }

    @State private var showRecoveryPhrase = false
    /// The identity whose invite-key share view is presented, if any.
    @State private var shareIdentity: IdentitySummary?

    /// First / second gate of the "clear message cache" double-confirm.
    @State private var showClearConfirm1 = false
    @State private var showClearConfirm2 = false

    /// Confirmation gate for Restart Onboarding. Single confirm —
    /// unlike the message-cache clear, nothing is deleted: identity,
    /// chats, messages, and every current selection are kept.
    @State private var showRestartOnboardingConfirm = false

    /// Persisted in `UserDefaults` under the same key
    /// `UserDefaultsNetworkPreference` reads. Toggling here changes
    /// the network the next Create Group flow will use.
    @AppStorage(UserDefaultsNetworkPreference.storageKey) private var useMainnet = false

    /// Symmetric read receipts (default ON): gates both sending your
    /// read receipts and seeing others'. Same key as
    /// `ReadReceiptsPreference`.
    @AppStorage(ReadReceiptsPreference.storageKey) private var sendReadReceipts = true

    public var body: some View {
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

                if let makeDiscoverySettingsFlow {
                    SettingsSectionLabel("DISCOVERY")
                    SettingsCard {
                        NavigationLink {
                            DiscoverySettingsView(flow: makeDiscoverySettingsFlow())
                        } label: {
                            SettingsRow(
                                title: "Discovery Providers",
                                subtitle: "Catalogs of relays and services",
                                last: true
                            ) {
                                SettingsIconTile(symbol: "sparkle.magnifyingglass",
                                                 bg: SettingsTile.purple)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.discovery_row")
                    }
                    SettingsFootnote("Discovery providers publish signed catalogs of services you can adopt. You choose which providers to trust — each one's key is pinned when you add it.")
                }

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

                // Hidden until the app wires the push stack, like the
                // other optional sections.
                if let makeNotificationsSettingsFlow {
                    SettingsSectionLabel("NOTIFICATIONS")
                    SettingsCard {
                        NavigationLink {
                            NotificationsSettingsView(flow: makeNotificationsSettingsFlow())
                        } label: {
                            SettingsRow(
                                title: "Notifications",
                                subtitle: "Content-free wakes, off by default",
                                last: true
                            ) {
                                SettingsIconTile(
                                    symbol: "bell.badge.fill",
                                    bg: SettingsTile.indigo
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.notifications_row")
                    }
                    SettingsFootnote("Off means no third party ever learns this device wants waking. On hands Onym's push server your inbox codes and Apple a content-free alert — never message content.")
                }

                // Absent until the app supplies it, like every other
                // optional section here — a build without backup wired
                // shows no backup row rather than a dead one.
                //
                // EITHER factory raises the section. Device Backup only
                // exists once an operator has been consented to, so
                // gating the section on it alone made the operator
                // picker unreachable from the state everybody starts
                // in: no consent, therefore no section, therefore
                // nowhere to consent.
                if makeDeviceBackupView != nil || makeBackupOperatorSettingsFlow != nil {
                    SettingsSectionLabel("BACKUP")
                    SettingsCard {
                        if let makeDeviceBackupView {
                            NavigationLink {
                                makeDeviceBackupView()
                            } label: {
                                SettingsRow(
                                    title: "Device Backup",
                                    subtitle: "Sealed copies of this phone's history",
                                    // Last only when the picker row is
                                    // absent, so the card never draws a
                                    // divider under its final row.
                                    last: makeBackupOperatorSettingsFlow == nil
                                ) {
                                    SettingsIconTile(
                                        symbol: "externaldrive.badge.timemachine",
                                        bg: SettingsTile.blue)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.device_backup_row")
                        }
                        if let makeBackupOperatorSettingsFlow {
                            NavigationLink {
                                BackupOperatorSettingsView(flow: makeBackupOperatorSettingsFlow())
                            } label: {
                                SettingsRow(
                                    title: "Backup Operators",
                                    // Names the second copy on purpose:
                                    // consenting to another operator
                                    // adds one, it does not move the
                                    // first, and that is the sentence
                                    // the enrolment screen goes on to
                                    // repeat.
                                    subtitle: "Find an operator to hold a copy",
                                    last: true
                                ) {
                                    SettingsIconTile(
                                        symbol: "externaldrive.badge.plus",
                                        bg: SettingsTile.blue)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.backup_operators_row")
                        }
                    }
                    SettingsFootnote("A backup is sealed on this phone before it leaves. The operator keeps bytes it cannot read, and only your recovery phrase can open them.")
                }

                // The section gates on the two original factories; the
                // case factory only enriches the open-case banner and
                // must not make the whole MODERATION entry vanish for
                // callers that don't supply it.
                if let makeModerationSettingsFlow, let makeModerationConsentFlow {
                    SettingsSectionLabel("MODERATION")
                    SettingsCard {
                        NavigationLink {
                            ModerationSettingsView(
                                flow: makeModerationSettingsFlow(),
                                makeConsentFlow: makeModerationConsentFlow,
                                makeCaseFlow: makeModerationCaseFlow
                            )
                        } label: {
                            SettingsRow(
                                title: "Moderation",
                                subtitle: "Your consented authority and its terms",
                                last: true
                            ) {
                                SettingsIconTile(symbol: "checkmark.shield", bg: SettingsTile.green)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.moderation_row")
                    }
                    SettingsFootnote("The moderation authority handles reports of prohibited content under terms you consented to. You can switch to a different authority at any time.")
                }

                if onRestartOnboarding != nil {
                    SettingsSectionLabel("SETUP")
                    SettingsCard {
                        Button { showRestartOnboardingConfirm = true } label: {
                            SettingsRow(
                                title: "Restart Onboarding",
                                subtitle: "Review your service choices again",
                                hasChevron: false,
                                last: true
                            ) {
                                SettingsIconTile(symbol: "arrow.counterclockwise.circle.fill",
                                                 bg: SettingsTile.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.restart_onboarding_row")
                    }
                    SettingsFootnote("Runs the first-launch setup again: message transport, file storage, notary, and moderation. Your identity, chats, and messages are kept, and your current choices stay until you change them.")
                }

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
        .alert("Restart onboarding?", isPresented: $showRestartOnboardingConfirm) {
            Button("Restart Setup") { onRestartOnboarding?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The first-launch setup runs again so you can review who carries your messages, stores your files, notarizes your history, and moderates reports.\n\nNothing is deleted: your identity, chats, and messages are kept, and your current choices stay until you change them.")
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
