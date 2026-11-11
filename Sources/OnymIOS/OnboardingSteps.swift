import SwiftUI
import OnymChain
import OnymDesign
import OnymDiscovery
import OnymFoundation
import OnymIdentity
import OnymModerationUI
import OnymOnboarding
import OnymRecovery
import OnymSettings
import OnymTransportBlossom
import OnymTransportNostr

// App-layer step content for the first-launch onboarding cover.
//
// `OnboardingView` (Packages/OnymOnboarding) renders the frame of each
// step — title, subtitle, Continue / Skip / Back, the step indicator —
// and takes each step's body through its `stepContent` slot. The
// bodies here are the real surfaces, pre-bound by `OnymIOSApp` to the
// SAME repositories, catalog pickers, and consent flows the Settings
// screens use: a choice made during onboarding and a choice made later
// in Settings run the exact same code.
//
// Accessibility identifiers follow the scaffold's convention:
// `onboarding.<step>.<element>`.

/// Everything the step bodies need, bundled so `OnymIOSApp` hands one
/// value to `AppDependencies.makeOnboardingStepContent`. Each factory
/// is the verbatim closure the corresponding Settings screen uses.
@MainActor
struct OnboardingStepContentBuilder {
    /// nil when the app runs without discovery (UI-test harness) —
    /// the discovery step then renders an informational body and the
    /// catalog sections stay empty, exactly like Settings.
    let makeDiscoveryFlow: (@MainActor () -> DiscoverySettingsFlow)?
    let makeNostrFlow: @MainActor () -> NostrRelaySettingsFlow
    let nostrPicker: DiscoveryModulePicker?
    let makeBlossomFlow: @MainActor () -> BlossomRelaySettingsFlow
    let blossomPicker: DiscoveryModulePicker?
    let makeRelayerFlow: @MainActor () -> RelayerSettingsFlow
    let relayerPicker: DiscoveryModulePicker?
    let makeModerationConsentFlow: @MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow
    let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    /// Awaits the identity bootstrap and answers whether a snapshot
    /// exists — the identity step's checklist binds to this instead of
    /// asserting success it can't know about.
    let identityReady: @MainActor () async -> Bool
    /// The welcome step's "I have a recovery phrase" path. Replaces
    /// whatever identity the WindowGroup task already minted with the
    /// one the entered mnemonic describes — same
    /// `IdentityRepository.restore(mnemonic:)` the recovery-phrase
    /// backup flow's semantics rest on. Throws on an invalid phrase.
    let identityRestore: @MainActor (String) async throws -> Void
    /// `restore(mnemonic:)` wipes every existing identity — safe only
    /// on a genuine fresh install. False on a Settings → Restart
    /// Onboarding walk (which keeps identity/chats/messages by
    /// design), hiding the affordance entirely rather than risking a
    /// silent wipe of live data.
    let identityRestoreAllowed: Bool
    let loadSummary: @MainActor () async -> [OnboardingSummaryRow]

    func content(for step: OnboardingStep, flow: OnboardingFlow) -> AnyView? {
        switch step {
        case .welcome:
            // The welcome screen is the door alone — no body.
            return nil
        case .identity:
            return AnyView(OnboardingIdentityContent(
                onboarding: flow,
                identityReady: identityReady
            ))
        case .services:
            return AnyView(OnboardingServicesContent(
                onboarding: flow,
                builder: self
            ))
        case .moderation:
            return AnyView(OnboardingModerationContent(
                onboarding: flow,
                makeConsentFlow: makeModerationConsentFlow
            ))
        case .recoveryPhrase: // onym:allow-secret-read — step name, not the phrase
            return AnyView(OnboardingRecoveryContent(
                onboarding: flow,
                makeBackupFlow: makeBackupFlow
            ))
        case .done:
            return AnyView(OnboardingDoneContent(
                onboarding: flow,
                makeBackupFlow: makeBackupFlow,
                loadSummary: loadSummary
            ))
        }
    }

    /// A step's alternative action. Only Welcome has one: restoring
    /// from a phrase, the genuine alternative to starting fresh,
    /// rendered as an icon in the welcome screen's bottom row.
    func secondaryAction(for step: OnboardingStep, flow: OnboardingFlow) -> AnyView? {
        // Hidden on a Settings → Restart Onboarding walk: that path
        // keeps identity/chats/messages by design, and
        // `restore(mnemonic:)` wipes all of it — this affordance must
        // only ever be reachable where nothing is at stake.
        guard step == .welcome, identityRestoreAllowed else { return nil }
        return AnyView(OnboardingRestoreButton(
            onboarding: flow,
            identityRestore: identityRestore
        ))
    }
}

// MARK: - Shared bits

/// Plain informational card used by steps with nothing actionable
/// (discovery absent, empty lists).
private struct OnboardingInfoCard: View {
    let text: LocalizedStringKey
    var accessibilityID: String? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier(accessibilityID ?? "onboarding.info")
    }
}

/// One configured-endpoint row (name + role chip + URL), shared by the
/// transport steps. The role chip on the first row ("Primary" /
/// "Active") is the "preselected default" affordance — the seed is
/// already installed, tapping Continue keeps it.
private struct OnboardingEndpointRow: View {
    let name: String
    let url: URL
    let badge: LocalizedStringKey?
    let selected: Bool
    var badgeColor: Color = OnymTokens.text2
    var last: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? OnymAccent.blue.color : OnymTokens.text3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    Text(url.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OnymTokens.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.14),
                                    in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !last {
                Divider()
                    .background(OnymTokens.hairline)
                    .padding(.leading, 46)
            }
        }
    }
}

/// Custom-URL entry row (field + Add button) shared by the transport /
/// notary steps — same behavior as the Settings screens' custom-URL
/// cards, driven by the same flow intents.
private struct OnboardingCustomURLField: View {
    let placeholder: String
    let draft: Binding<String>
    let error: String?
    let accessibilityPrefix: String
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(OnymTokens.text)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(OnymTokens.surface3,
                                in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("\(accessibilityPrefix).custom_url_field")
                Button(action: onAdd) {
                    Text("Add")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnymTokens.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(OnymAccent.blue.color,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("\(accessibilityPrefix).add_custom")
            }
            if let error {
                Text(verbatim: error)
                    .font(.system(size: 12))
                    .foregroundStyle(OnymTokens.red)
                    .accessibilityIdentifier("\(accessibilityPrefix).custom_error")
            }
        }
        .padding(14)
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Section header used inside step bodies (the scaffold already
/// applies the page's horizontal padding, so no extra inset here).
private struct OnboardingSectionLabel: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(OnymTokens.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }
}

// MARK: - Welcome

/// The welcome step's "I have a recovery phrase" affordance — an
/// icon in the screen's bottom row, beside step-by-step setup. Owns
/// the sheet it presents, and advances the flow only once the restore
/// lands.
private struct OnboardingRestoreButton: View {
    let onboarding: OnboardingFlow
    let identityRestore: @MainActor (String) async throws -> Void
    @State private var showRestore = false

    var body: some View {
        Button {
            showRestore = true
        } label: {
            // Same metrics as the step-by-step icon it sits beside.
            Image(systemName: "key.fill")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(Text("I have a recovery phrase"))
        .accessibilityIdentifier("onboarding.welcome.restore")
        .sheet(isPresented: $showRestore) {
            OnboardingRestoreSheet(identityRestore: identityRestore) {
                showRestore = false
                onboarding.identityOrigin = .restored
                onboarding.advance()
            }
        }
    }
}

/// The welcome step's "I have a recovery phrase" sheet — an existing
/// mnemonic replaces whatever identity the WindowGroup task already
/// minted (`IdentityRepository.restore(mnemonic:)`; the additive
/// `add(mnemonic:)` used by Settings' second-identity flow is the
/// wrong call here, since there is nothing else on this fresh install
/// worth keeping alongside it). `onRestored` fires only after the
/// repository call actually succeeds.
private struct OnboardingRestoreSheet: View {
    let identityRestore: @MainActor (String) async throws -> Void
    let onRestored: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var phrase = ""
    @State private var error: String?
    @State private var isRestoring = false

    private var wordCount: Int {
        phrase.split(whereSeparator: { $0.isWhitespace }).count
    }
    private var canRestore: Bool { wordCount == 12 || wordCount == 24 }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Enter the 12 or 24-word recovery phrase for the identity you're bringing to this device.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(2)

                Card {
                    TextField("word word word …", text: $phrase, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .lineLimit(3...6)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("onboarding.welcome.restore.phrase_field")
                }

                if let error {
                    Text(verbatim: error)
                        .font(.system(size: 13))
                        .foregroundStyle(OnymTokens.red)
                        .accessibilityIdentifier("onboarding.welcome.restore.error")
                }

                Text("This replaces the identity Onym just created on this device with the one these words describe. Nothing else here is touched.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnymTokens.text2)
                    .lineSpacing(2)

                Spacer(minLength: 0)

                PrimaryButton(isRestoring ? "Restoring…" : "Restore identity") {
                    Task { await submit() }
                }
                .disabled(!canRestore || isRestoring)
                .opacity(canRestore ? 1 : 0.5)
                .accessibilityIdentifier("onboarding.welcome.restore.submit")
            }
            .padding(20)
            .background(OnymTokens.surface.ignoresSafeArea())
            .navigationTitle("Recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isRestoring)
                }
            }
        }
        .interactiveDismissDisabled(isRestoring)
    }

    private func submit() async {
        guard canRestore else { return }
        error = nil
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await identityRestore(phrase.trimmingCharacters(in: .whitespacesAndNewlines))
            onRestored()
        } catch IdentityError.invalidMnemonic {
            error = String(localized: "That doesn't look like a valid 12 or 24-word phrase.")
        } catch {
            self.error = String(localized: "Couldn't restore that identity. Check the phrase and try again.")
        }
    }
}

// MARK: - Identity

/// "Making your keys" — the identity bootstrap already runs in the
/// WindowGroup task; this step BINDS to it instead of asserting
/// success it can't know about. A spinner while the bootstrap
/// resolves, nothing once a snapshot exists, and a retry if it
/// doesn't. The step is
/// outcome-gated (`requiresOutcomeToAdvance`): Continue stays
/// disabled until a snapshot exists, because a failed bootstrap must
/// not walk the user on to services and a recovery step whose reveal
/// cannot work.
struct OnboardingIdentityContent: View {
    let onboarding: OnboardingFlow
    let identityReady: @MainActor () async -> Bool

    private enum Phase {
        case checking
        case ready
        case failed
    }

    @State private var phase: Phase = .checking
    @State private var attempt = 0

    /// One key, centred by the scaffold, its state badged on its
    /// corner: a spinner while the bootstrap resolves, a green check
    /// once the key exists. A failure badges a red cross and puts a
    /// retry under the key — as an overlay, so the key stays centred.
    var body: some View {
        Image(systemName: "key.horizontal.fill")
            .font(.system(size: 72, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 120, height: 120)
            .overlay(alignment: .bottomTrailing) {
                Group {
                    switch phase {
                    case .checking:
                        ProgressView()
                            .controlSize(.large)
                            .accessibilityLabel(Text(onboarding.identityOrigin == .restored
                                ? "Restoring your identity"
                                : "Making your keys"))
                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(OnymTokens.green)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel(Text(onboarding.identityOrigin == .restored
                                ? "Identity key restored"
                                : "Identity key created"))
                            .accessibilityIdentifier("onboarding.identity.ready")
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(OnymTokens.red)
                            .accessibilityLabel(Text("Your keys couldn't be created. Nothing was sent anywhere — try again."))
                    }
                }
                .background(OnymTokens.surface, in: Circle())
                .offset(x: 10, y: 10)
            }
            .overlay(alignment: .bottom) {
                if case .failed = phase {
                    Button {
                        attempt += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(OnymTokens.red)
                    .accessibilityLabel(Text("Try again"))
                    .accessibilityIdentifier("onboarding.identity.retry")
                    .offset(y: 84)
                }
            }
            .animation(.spring(duration: 0.35), value: phase)
        .task(id: attempt) {
            phase = .checking
            let ready = await identityReady()
            // A cancelled probe (navigation tore the task down while
            // `try?` inside identityReady swallowed CancellationError)
            // must not masquerade as a bootstrap failure.
            guard !Task.isCancelled else { return }
            if ready {
                phase = .ready
                // Unlocks the step's Continue — nothing was decided
                // here, but the gate needs proof the keys exist.
                // recordOutcome writes to the CURRENT step; guard
                // against the probe resolving after a quick Back.
                if onboarding.step == .identity {
                    onboarding.recordOutcome(.notApplicable)
                }
            } else {
                phase = .failed
            }
        }
    }
}

// MARK: - Services (recommended vs. choose myself)

/// "Your services" — one screen instead of the old four wizard steps.
/// The recommended setup (the seeded defaults plus whatever the
/// published lists install) is preselected; "Choose services myself"
/// opens the hub sheet, whose per-seat screens are the SAME surfaces
/// the old wizard steps rendered, backed by the same Settings flows.
struct OnboardingServicesContent: View {
    let onboarding: OnboardingFlow
    let builder: OnboardingStepContentBuilder
    @State private var showHub = false

    /// Derived from the flow, never view-local — Back/forward
    /// navigation rebuilds this view, and the chip must keep telling
    /// the truth about what the user configured.
    private var usingCustom: Bool {
        onboarding.servicesChoice == .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recommendedCard
            customCard
        }
        // The screen shows "Selected" on the recommended card from the
        // first frame, so the outcome must say the same thing:
        // Continue from here IS accepting the recommended setup, not
        // walking past an unanswered question. Seeding also makes
        // tapping the already-selected card an honest no-op.
        .task {
            if onboarding.step == .services, onboarding.outcomes[.services] == nil {
                onboarding.recordOutcome(.consented(componentId: nil))
            }
        }
        .sheet(isPresented: $showHub) {
            OnboardingServicesHub(
                onboarding: onboarding,
                builder: builder,
                onUseRecommended: {
                    // Only the choice reverts — consent pins and
                    // endpoints the sub-surfaces persisted stay (the
                    // hub's footnote says so); explicitly accepting
                    // the recommended path is still a consent.
                    onboarding.servicesChoice = .recommended
                    onboarding.recordOutcome(.consented(componentId: nil))
                    showHub = false
                },
                onDone: {
                    onboarding.servicesChoice = .custom
                    // The hub's per-seat surfaces record specific
                    // consents (with componentIds) as they happen —
                    // keep those; otherwise closing the hub still
                    // means "I set things up myself". All seats share
                    // the single `.services` outcome, so what survives
                    // here is whichever seat consented LAST — arbitrary
                    // but harmless: the Done step's summary reads live
                    // repository state, not this outcome.
                    if case .consented(let componentId)? = onboarding.outcomes[.services],
                       componentId != nil {
                        // keep the specific consent
                    } else {
                        onboarding.recordOutcome(.consented(componentId: nil))
                    }
                    showHub = false
                }
            )
        }
    }

    private var recommendedCard: some View {
        Button {
            // An explicit affirmative pick of the recommended setup is
            // a consent — distinct from walking past the screen, which
            // advance() backfills as `.notApplicable`.
            onboarding.servicesChoice = .recommended
            onboarding.recordOutcome(.consented(componentId: nil))
        } label: {
            // The recommended set as its four seats' icons — delivery,
            // media, group integrity, directory: the fixed promise the
            // Done step's summary then shows live.
            HStack(spacing: 0) {
                ForEach(Self.recommendedSeats, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(OnymAccent.blue.color)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(usingCustom ? Color.clear : OnymAccent.blue.color, lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) { selectedBadge(!usingCustom) }
        }
        .accessibilityLabel(Text("Recommended setup"))
        .accessibilityHint(Text("Published by Onym, verified on this device. None of it is a login — swap any piece later."))
        .accessibilityAddTraits(usingCustom ? [] : .isSelected)
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.services.recommended")
    }

    private var customCard: some View {
        Button {
            showHub = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .background(OnymTokens.surface2,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(usingCustom ? OnymAccent.blue.color : Color.clear, lineWidth: 2)
                )
                .overlay(alignment: .topTrailing) { selectedBadge(usingCustom) }
        }
        .accessibilityLabel(Text("Choose services myself"))
        .accessibilityHint(Text("Pick your own directories, relays, storage and notaries. About two minutes."))
        .accessibilityAddTraits(usingCustom ? .isSelected : [])
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.services.custom")
    }

    private static let recommendedSeats = [
        "antenna.radiowaves.left.and.right",
        "photo.on.rectangle.angled",
        "checkmark.seal",
        "magnifyingglass",
    ]

    /// Stands in for the old "Selected" chip.
    @ViewBuilder
    private func selectedBadge(_ selected: Bool) -> some View {
        if selected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(OnymAccent.blue.color)
                .padding(10)
                .accessibilityHidden(true)
        }
    }
}

/// The "choose services myself" hub: each seat is a pushed screen
/// hosting the exact surface the old wizard step rendered. Replaces
/// the old forced discovery → transport → storage → notary sequence
/// with set-up-as-much-as-you-like navigation.
struct OnboardingServicesHub: View {
    let onboarding: OnboardingFlow
    let builder: OnboardingStepContentBuilder
    let onUseRecommended: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Set up as much or as little as you like — anything you leave alone keeps the recommended default.")
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                        .lineSpacing(2)
                        .padding(.bottom, 4)

                    OnboardingSectionLabel(text: "NEEDED TO SEND MESSAGES")
                    VStack(spacing: 0) {
                        hubRow(
                            id: "messageDelivery",
                            symbol: "antenna.radiowaves.left.and.right",
                            color: OnymAccent.purple.color,
                            title: "Message delivery",
                            subtitle: "Who carries your sealed messages"
                        ) {
                            AnyView(OnboardingNostrContent(
                                onboarding: onboarding,
                                makeFlow: builder.makeNostrFlow,
                                picker: builder.nostrPicker
                            ))
                        }
                        divider
                        hubRow(
                            id: "mediaDelivery",
                            symbol: "photo.on.rectangle.angled",
                            color: OnymAccent.pink.color,
                            title: "Media delivery",
                            subtitle: "Carries photos, video and voice notes"
                        ) {
                            AnyView(OnboardingBlossomContent(
                                onboarding: onboarding,
                                makeFlow: builder.makeBlossomFlow,
                                picker: builder.blossomPicker
                            ))
                        }
                        divider
                        hubRow(
                            id: "directory",
                            symbol: "magnifyingglass",
                            color: OnymAccent.blue.color,
                            title: "Directory",
                            subtitle: "Where Onym looks services up"
                        ) {
                            AnyView(OnboardingDiscoveryContent(
                                onboarding: onboarding,
                                makeFlow: builder.makeDiscoveryFlow
                            ))
                        }
                    }
                    .background(OnymTokens.surface2,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    OnboardingSectionLabel(text: "OPTIONAL")
                    VStack(spacing: 0) {
                        hubRow(
                            id: "groupIntegrity",
                            symbol: "checkmark.seal",
                            color: OnymAccent.green.color,
                            title: "Group integrity",
                            subtitle: "Keeps group membership provably honest"
                        ) {
                            AnyView(OnboardingNotaryContent(
                                onboarding: onboarding,
                                makeFlow: builder.makeRelayerFlow,
                                picker: builder.relayerPicker
                            ))
                        }
                    }
                    .background(OnymTokens.surface2,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("More than one service works differently per category: relays all carry every message together, extra media hosts are trusted download sources, and each new group picks its notary from your list.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(OnymTokens.text2)
                        .lineSpacing(2)
                        .padding(.top, 12)

                    Button(action: onUseRecommended) {
                        Text("Use the recommended setup instead")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OnymAccent.blue.color)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 20)
                    .accessibilityIdentifier("onboarding.services.hub.use_recommended")

                    // This switches the selection back, it does NOT
                    // undo anything — say so, or the affordance reads
                    // as a revert.
                    Text("Anything you already added here stays configured — you can remove it later in Settings → Services.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnymTokens.text3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(Text("Your services"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .accessibilityIdentifier("onboarding.services.hub.done")
                }
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var divider: some View {
        Divider()
            .background(OnymTokens.hairline)
            .padding(.leading, 50)
    }

    private func hubRow(
        id: String,
        symbol: String,
        color: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        destination: @escaping () -> AnyView
    ) -> some View {
        NavigationLink {
            OnboardingHubDetail(title: title, content: destination)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnymTokens.onAccent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(OnymTokens.text2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnymTokens.text3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.services.hub.\(id)")
    }
}

/// One pushed hub screen: the seat's surface inside a scroll view with
/// the page insets the scaffold used to provide.
private struct OnboardingHubDetail: View {
    let title: LocalizedStringKey
    let content: () -> AnyView

    var body: some View {
        ScrollView {
            content()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Discovery confirm

/// TOFU-confirm the seeded default discovery source — the same
/// fetch → fingerprint hero → pin-on-explicit-confirm path the
/// Settings "Confirm…" affordance drives, through the same
/// `DiscoverySettingsFlow` — plus an "add your own provider" secondary
/// that feeds the same add path. Skippable: later steps fall back to
/// the legacy published lists exactly as the app does today.
struct OnboardingDiscoveryContent: View {
    let onboarding: OnboardingFlow
    @State private var flow: DiscoverySettingsFlow?
    @State private var showAddOwn = false

    init(onboarding: OnboardingFlow, makeFlow: (@MainActor () -> DiscoverySettingsFlow)?) {
        self.onboarding = onboarding
        _flow = State(initialValue: makeFlow?())
    }

    var body: some View {
        if let flow {
            content(flow)
                .task { flow.start() }
                .onDisappear { flow.stop() }
                .onChange(of: isAdded(flow)) { _, added in
                    // Pinning the key IS the consent at this step —
                    // there's no componentId; the pin is to a provider
                    // source, not a catalog component.
                    if added {
                        onboarding.recordOutcome(.consented(componentId: nil))
                    }
                }
        } else {
            OnboardingInfoCard(
                text: "This build runs without a service directory. Continue — the app uses its built-in defaults.",
                accessibilityID: "onboarding.services.directory.unavailable"
            )
        }
    }

    private func isAdded(_ flow: DiscoverySettingsFlow) -> Bool {
        if case .added = flow.addPhase { return true }
        return false
    }

    @ViewBuilder
    private func content(_ flow: DiscoverySettingsFlow) -> some View {
        switch flow.addPhase {
        case .idle:
            idle(flow)
        case .fetching:
            HStack(spacing: 10) {
                ProgressView()
                Text("Fetching the provider's manifest…")
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        case .confirming(let preview):
            confirm(flow, preview: preview)
        case .added:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(OnymTokens.green)
                Text("Provider confirmed")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OnymTokens.text)
                Text("Its catalogs are being fetched and verified now — the next steps can offer what it lists.")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.text2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .accessibilityIdentifier("onboarding.services.directory.added")
        }
    }

    @ViewBuilder
    private func idle(_ flow: DiscoverySettingsFlow) -> some View {
        Text("A directory is a phone book of available services. Onym verifies every entry on this device before showing it to you — adding a second one widens what you can choose from.")
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(3)
            .padding(.bottom, 12)

        if let status = flow.state.sources.first {
            OnboardingSectionLabel(text: "IN USE")
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: status.source.userLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    Text(status.source.manifestURL.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OnymTokens.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let fingerprint = status.source.operatorKeyFingerprint {
                        Text(verbatim: String(localized: "Key \(fingerprint)"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OnymTokens.text2)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("onboarding.services.directory.source")

            if status.source.pinnedOperatorKeyHex == nil {
                PrimaryButton("Verify & Confirm") {
                    flow.tappedConfirmSource(providerId: status.source.providerId)
                }
                .padding(.top, 12)
                .accessibilityIdentifier("onboarding.services.directory.confirm")
            } else {
                Label("Already confirmed — its key is pinned.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.green)
                    .padding(.top, 12)
                    .accessibilityIdentifier("onboarding.services.directory.pinned")
            }
        } else {
            OnboardingInfoCard(
                text: "No discovery provider is configured yet. Add your own below, or continue with the built-in defaults.",
                accessibilityID: "onboarding.services.directory.empty"
            )
        }

        if let error = flow.addError {
            Text(verbatim: error)
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.red)
                .padding(.top, 8)
                .accessibilityIdentifier("onboarding.services.directory.error")
        }

        addOwn(flow)
    }

    /// "Add your own provider URL" secondary — the same
    /// fetch-then-TOFU path, aimed at a URL the user types.
    @ViewBuilder
    private func addOwn(_ flow: DiscoverySettingsFlow) -> some View {
        @Bindable var flow = flow
        if showAddOwn {
            OnboardingSectionLabel(text: "ADD YOUR OWN")
            VStack(alignment: .leading, spacing: 8) {
                TextField("https://discovery.example.com/manifest.json", text: $flow.addDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(OnymTokens.surface3,
                                in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("onboarding.services.directory.add_url_field")
                Button {
                    flow.tappedFetchProvider()
                } label: {
                    Text("Fetch Provider")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnymAccent.blue.color)
                }
                .accessibilityIdentifier("onboarding.services.directory.fetch")
            }
            .padding(14)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            Button {
                showAddOwn = true
            } label: {
                Text("Add your own provider URL")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OnymAccent.blue.color)
            }
            .padding(.top, 12)
            .accessibilityIdentifier("onboarding.services.directory.add_own")
        }
    }

    /// The TOFU confirmation: fingerprint hero + provider summary.
    /// Nothing is pinned until "Pin Key & Confirm".
    @ViewBuilder
    private func confirm(_ flow: DiscoverySettingsFlow, preview: DiscoveryProviderPreview) -> some View {
        Text("This fingerprint identifies the provider's operator key. Verify it out-of-band before confirming — it's pinned on confirm, and a later manifest signed by any other key will be rejected.")
            .font(.system(size: 13.5))
            .foregroundStyle(OnymTokens.text2)
            .lineSpacing(3)

        Text(verbatim: preview.operatorKeyFingerprint)
            .font(.system(size: 26, weight: .semibold, design: .monospaced))
            .foregroundStyle(OnymTokens.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 12)
            .accessibilityIdentifier("onboarding.services.directory.fingerprint")

        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: preview.providerId)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
            Text(preview.manifestURL.absoluteString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(OnymTokens.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 8)

        PrimaryButton("Pin Key & Confirm") {
            flow.tappedConfirmAdd()
        }
        .padding(.top, 12)
        .accessibilityIdentifier("onboarding.services.directory.pin")

        Button("Not now") { flow.tappedCancelPreview() }
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text2)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .accessibilityIdentifier("onboarding.services.directory.cancel_preview")
    }
}

// MARK: - Message transport (Nostr)

/// Choose who relays messages. The seeded Onym Official relay renders
/// preselected; the discovery catalog section runs `ModuleConsentFlow`
/// (as a sheet, like Settings); a custom URL adds without consent —
/// the user's own typed endpoint is their own choice, not a
/// catalog-published module.
struct OnboardingNostrContent: View {
    let onboarding: OnboardingFlow
    @State private var flow: NostrRelaySettingsFlow
    let picker: DiscoveryModulePicker?
    @State private var consentEntry: AttributedCatalogEntry?
    @State private var lastConsentEntry: AttributedCatalogEntry?

    init(
        onboarding: OnboardingFlow,
        makeFlow: @MainActor () -> NostrRelaySettingsFlow,
        picker: DiscoveryModulePicker?
    ) {
        self.onboarding = onboarding
        _flow = State(initialValue: makeFlow())
        self.picker = picker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Relays pass sealed messages along. They can't read them, and they never learn who you're talking to. Every message is sent through all of your relays at once — any one of them is enough to reach you.")
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(3)
                .padding(.bottom, 4)

            configured

            catalogSection(prefix: "onboarding.services.messageDelivery.catalog")

            OnboardingSectionLabel(text: "ADD YOUR OWN")
            OnboardingCustomURLField(
                placeholder: "wss://relay.example.com",
                draft: Binding(
                    get: { flow.state.customDraft },
                    set: { flow.customDraftChanged($0) }
                ),
                error: flow.state.customDraftError,
                accessibilityPrefix: "onboarding.services.messageDelivery",
                onAdd: {
                    flow.tappedAddCustom()
                    if flow.state.customDraftError == nil {
                        onboarding.recordOutcome(.consented(componentId: nil))
                    }
                }
            )
        }
        .task { flow.start() }
        .onDisappear { flow.stop() }
        .sheet(item: $consentEntry, onDismiss: { consentDismissed() }) { entry in
            if let picker {
                ModuleConsentView(flow: picker.makeConsentFlow(entry))
            }
        }
    }

    @ViewBuilder
    private var configured: some View {
        let endpoints = flow.state.snapshot.endpoints
        if endpoints.isEmpty {
            OnboardingInfoCard(
                text: "No relay configured yet. Add one below, or go back to keep the default.",
                accessibilityID: "onboarding.services.messageDelivery.empty"
            )
        } else {
            // The label belongs to the non-empty list — over the
            // empty-state card it would caption nothing in use.
            OnboardingSectionLabel(text: "IN USE")
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    OnboardingEndpointRow(
                        name: endpoint.name,
                        url: endpoint.url,
                        // No per-row role: Nostr has no failover order.
                        // NostrMessageTransport fans every event out to
                        // ALL connected relays concurrently — claiming
                        // "backup" here would be a false privacy
                        // statement about which relays see traffic.
                        badge: nil,
                        selected: true,
                        last: idx == endpoints.count - 1
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding.services.messageDelivery.configured.\(endpoint.url.absoluteString)")
                }
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Every relay in this list carries every message — they're used together, not as fallbacks. Any one that's up is enough to reach you.")
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(2)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func catalogSection(prefix: String) -> some View {
        if !flow.catalogEntries.isEmpty {
            OnboardingSectionLabel(text: "SUGGESTED BY YOUR DIRECTORIES")
            DiscoveryCatalogSection(
                entries: flow.catalogEntries,
                activeConsent: { flow.activeConsent(for: $0) },
                consentedOffer: { flow.consentedOffer(for: $0) },
                tileSymbol: "antenna.radiowaves.left.and.right.circle.fill",
                accessibilityPrefix: prefix,
                // The hub screens draw their own "SUGGESTED BY YOUR
                // DIRECTORIES" header; nil avoids the section's
                // built-in "FROM CATALOG" doubling it.
                label: nil,
                onSelect: { entry in
                    lastConsentEntry = entry
                    consentEntry = entry
                }
            )
            // DiscoveryCatalogSection carries the Settings pages' own
            // horizontal insets; pull them back to the scaffold's.
            .padding(.horizontal, -16)
        }
    }

    private func consentDismissed() {
        flow.refreshCatalog()
        guard let entry = lastConsentEntry,
              let record = picker?.activeConsent(entry.entry.componentId),
              record.manifestHash == entry.entry.manifest.digest
        else { return }
        onboarding.recordOutcome(.consented(componentId: entry.entry.componentId))
    }
}

// MARK: - Blob transport (Blossom)

/// Choose where attachments are stored. Same shape as the message
/// transport step; a consented catalog pick becomes the ACTIVE (first)
/// server via `BlossomCatalogConsent.apply` — the picker's `apply`
/// closure from the composition root, unchanged.
struct OnboardingBlossomContent: View {
    let onboarding: OnboardingFlow
    @State private var flow: BlossomRelaySettingsFlow
    let picker: DiscoveryModulePicker?
    @State private var consentEntry: AttributedCatalogEntry?
    @State private var lastConsentEntry: AttributedCatalogEntry?

    init(
        onboarding: OnboardingFlow,
        makeFlow: @MainActor () -> BlossomRelaySettingsFlow,
        picker: DiscoveryModulePicker?
    ) {
        self.onboarding = onboarding
        _flow = State(initialValue: makeFlow())
        self.picker = picker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Photos, video and voice notes are too big for the relays that carry text, so they travel through a media service instead. They're encrypted on this device first — it only ever handles sealed blobs.")
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(3)
                .padding(.bottom, 4)

            configured

            if !flow.catalogEntries.isEmpty {
                OnboardingSectionLabel(text: "SUGGESTED BY YOUR DIRECTORIES")
                DiscoveryCatalogSection(
                    entries: flow.catalogEntries,
                    activeConsent: { flow.activeConsent(for: $0) },
                    consentedOffer: { flow.consentedOffer(for: $0) },
                    tileSymbol: "photo.on.rectangle.angled",
                    accessibilityPrefix: "onboarding.services.mediaDelivery.catalog",
                    // The hub screens draw their own "SUGGESTED BY YOUR
                    // DIRECTORIES" header; nil avoids the section's
                    // built-in "FROM CATALOG" doubling it.
                    label: nil,
                    onSelect: { entry in
                        lastConsentEntry = entry
                        consentEntry = entry
                    }
                )
                .padding(.horizontal, -16)
            }

            OnboardingSectionLabel(text: "ADD YOUR OWN")
            OnboardingCustomURLField(
                placeholder: "https://blossom.example.com",
                draft: Binding(
                    get: { flow.state.customDraft },
                    set: { flow.customDraftChanged($0) }
                ),
                error: flow.state.customDraftError,
                accessibilityPrefix: "onboarding.services.mediaDelivery",
                onAdd: {
                    flow.tappedAddCustom()
                    if flow.state.customDraftError == nil {
                        onboarding.recordOutcome(.consented(componentId: nil))
                    }
                }
            )
        }
        .task { flow.start() }
        .onDisappear { flow.stop() }
        .sheet(item: $consentEntry, onDismiss: { consentDismissed() }) { entry in
            if let picker {
                ModuleConsentView(flow: picker.makeConsentFlow(entry))
            }
        }
    }

    @ViewBuilder
    private var configured: some View {
        let endpoints = flow.state.snapshot.endpoints
        if endpoints.isEmpty {
            OnboardingInfoCard(
                text: "No server configured yet. Add one below, or go back to keep the default.",
                accessibilityID: "onboarding.services.mediaDelivery.empty"
            )
        } else {
            OnboardingSectionLabel(text: "IN USE")
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    OnboardingEndpointRow(
                        name: endpoint.name,
                        url: endpoint.url,
                        // Only the FIRST endpoint ever receives your
                        // uploads (BlossomCatalogConsent makes a pick
                        // active by putting it first). The rest are an
                        // allowlist of hosts you'll accept downloads
                        // from — not upload fallbacks, so no "backup"
                        // chip.
                        // Keyed entry, not the bare "ACTIVE" literal:
                        // that key's ru is feminine (АКТИВНАЯ, for the
                        // identity card); a service is masculine.
                        badge: idx == 0 ? "ACTIVE_SERVICE_CHIP" : nil,
                        selected: idx == 0,
                        badgeColor: OnymTokens.green,
                        last: idx == endpoints.count - 1
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding.services.mediaDelivery.configured.\(endpoint.url.absoluteString)")
                }
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Your uploads go through the active service only. Any others in the list are hosts you trust for downloading what people send you.")
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(2)
                .padding(.top, 8)
        }
    }

    private func consentDismissed() {
        flow.refreshCatalog()
        guard let entry = lastConsentEntry,
              let record = picker?.activeConsent(entry.entry.componentId),
              record.manifestHash == entry.entry.manifest.digest
        else { return }
        onboarding.recordOutcome(.consented(componentId: entry.entry.componentId))
    }
}

// MARK: - Notary (relayer)

/// Choose who timestamps conversation history. While onboarding is
/// incomplete the relayer repository's first-launch auto-populate is
/// suppressed (the `autoPopulatePolicy` seam), so the configured list
/// starts empty here: the published list and the catalog section are
/// the offers, and skipping installs the published defaults right
/// after completion.
struct OnboardingNotaryContent: View {
    let onboarding: OnboardingFlow
    @State private var flow: RelayerSettingsFlow
    let picker: DiscoveryModulePicker?
    @State private var consentEntry: AttributedCatalogEntry?
    @State private var lastConsentEntry: AttributedCatalogEntry?

    init(
        onboarding: OnboardingFlow,
        makeFlow: @MainActor () -> RelayerSettingsFlow,
        picker: DiscoveryModulePicker?
    ) {
        self.onboarding = onboarding
        _flow = State(initialValue: makeFlow())
        self.picker = picker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A notary keeps every group's membership and history honest. It checks each change with a zero-knowledge proof, so it can confirm a group is genuine without learning who is in it or what was said.")
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(3)
                .padding(.bottom, 4)

            configured

            OnboardingSectionLabel(text: "FROM THE PUBLISHED LIST")
            published

            if !flow.catalogEntries.isEmpty {
                OnboardingSectionLabel(text: "SUGGESTED BY YOUR DIRECTORIES")
                DiscoveryCatalogSection(
                    entries: flow.catalogEntries,
                    activeConsent: { flow.activeConsent(for: $0) },
                    consentedOffer: { flow.consentedOffer(for: $0) },
                    tileSymbol: "antenna.radiowaves.left.and.right",
                    accessibilityPrefix: "onboarding.services.groupIntegrity.catalog",
                    // The hub screens draw their own "SUGGESTED BY YOUR
                    // DIRECTORIES" header; nil avoids the section's
                    // built-in "FROM CATALOG" doubling it.
                    label: nil,
                    onSelect: { entry in
                        lastConsentEntry = entry
                        consentEntry = entry
                    }
                )
                .padding(.horizontal, -16)
            }

            OnboardingSectionLabel(text: "ADD YOUR OWN")
            OnboardingCustomURLField(
                placeholder: "https://relayer.example.com",
                draft: Binding(
                    get: { flow.state.customDraft },
                    set: { flow.customDraftChanged($0) }
                ),
                error: flow.state.customDraftError,
                accessibilityPrefix: "onboarding.services.groupIntegrity",
                onAdd: {
                    flow.tappedAddCustom()
                    if flow.state.customDraftError == nil {
                        onboarding.recordOutcome(.consented(componentId: nil))
                    }
                }
            )

            Text("Leave this empty to use the published defaults — they're installed automatically once setup finishes.")
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.text2)
                .padding(.top, 10)
        }
        .task { flow.start() }
        .onDisappear { flow.stop() }
        .sheet(item: $consentEntry, onDismiss: { consentDismissed() }) { entry in
            if let picker {
                ModuleConsentView(flow: picker.makeConsentFlow(entry))
            }
        }
    }

    @ViewBuilder
    private var configured: some View {
        let endpoints = flow.state.snapshot.configuration.endpoints
        if endpoints.isEmpty {
            OnboardingInfoCard(
                text: "No notary chosen yet. Pick one below, or leave this empty to use the published defaults.",
                accessibilityID: "onboarding.services.groupIntegrity.empty"
            )
        } else {
            let configuration = flow.state.snapshot.configuration
            OnboardingSectionLabel(text: "IN USE")
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    OnboardingEndpointRow(
                        name: endpoint.name,
                        url: endpoint.url,
                        // The chip reflects the ACTUAL selection
                        // strategy: under `.primary` exactly the
                        // endpoint `selectURL` would resolve is
                        // marked; under `.random` (the auto-populated
                        // default) no row is special — a new group
                        // picks one of these at random.
                        badge: isPrimary(endpoint, at: idx, in: configuration) ? "PRIMARY" : nil,
                        selected: true,
                        badgeColor: OnymTokens.green,
                        last: idx == endpoints.count - 1
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding.services.groupIntegrity.configured.\(endpoint.url.absoluteString)")
                }
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(configuration.strategy == .primary
                 ? "New groups are notarised by your primary notary."
                 : "When you create a group, Onym picks one of these notaries at random for it — everyone in that group then uses the same one.")
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(2)
                .padding(.top, 8)
        }
    }

    /// Whether this row is the endpoint `RelayerConfiguration.selectURL`
    /// would actually resolve under the `.primary` strategy: the
    /// matching `primaryURL`, or `endpoints.first` when no primary is
    /// pinned (selectURL's documented fallback). Never true under
    /// `.random`.
    private func isPrimary(
        _ endpoint: RelayerEndpoint,
        at index: Int,
        in configuration: RelayerConfiguration
    ) -> Bool {
        guard configuration.strategy == .primary else { return false }
        if let primaryURL = configuration.primaryURL,
           configuration.endpoints.contains(where: { $0.url == primaryURL }) {
            return endpoint.url == primaryURL
        }
        return index == 0
    }

    /// The legacy published list — tap to add, no consent sheet: these
    /// entries are published by the onym-relayer project, not consented
    /// catalog modules.
    @ViewBuilder
    private var published: some View {
        let unconfigured = flow.unconfiguredKnownList
        VStack(spacing: 0) {
            switch flow.state.snapshot.fetchStatus {
            case .idle, .fetching:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Fetching list…")
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .accessibilityIdentifier("onboarding.services.groupIntegrity.published.fetching")
            case .failed(let message):
                Text(verbatim: message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(OnymTokens.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .accessibilityIdentifier("onboarding.services.groupIntegrity.published.failed")
            case .success where unconfigured.isEmpty:
                Text("All published notaries added.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .accessibilityIdentifier("onboarding.services.groupIntegrity.published.all_added")
            case .success:
                ForEach(Array(unconfigured.enumerated()), id: \.element.url) { idx, endpoint in
                    Button {
                        flow.tappedAddKnown(endpoint)
                        onboarding.recordOutcome(.consented(componentId: nil))
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Circle().fill(OnymAccent.blue.color)
                                    .frame(width: 24, height: 24)
                                    .overlay(Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(OnymTokens.onAccent))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: endpoint.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(OnymTokens.text)
                                    Text(endpoint.url.absoluteString)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(OnymTokens.text3)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                HStack(spacing: 4) {
                                    ForEach(endpoint.networks, id: \.self) { net in
                                        Chip(
                                            text: net.uppercased(),
                                            fg: net == "public" ? OnymTokens.red : OnymTokens.green,
                                            bg: (net == "public" ? OnymTokens.red : OnymTokens.green).opacity(0.15)
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            if idx != unconfigured.count - 1 {
                                Divider()
                                    .background(OnymTokens.hairline)
                                    .padding(.leading, 50)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding.services.groupIntegrity.published.\(endpoint.url.absoluteString)")
                }
            }
        }
        .background(OnymTokens.surface2,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func consentDismissed() {
        flow.refreshCatalog()
        guard let entry = lastConsentEntry,
              let record = picker?.activeConsent(entry.entry.componentId),
              record.manifestHash == entry.entry.manifest.digest
        else { return }
        onboarding.recordOutcome(.consented(componentId: entry.entry.componentId))
    }
}

// MARK: - Moderation

/// The moderation mandate flow, embedded: directory pick → hash-pinned
/// manifest review → sign, rendered by the same
/// `ModerationConsentContent` the blocking consent cover uses. A signed
/// mandate records the consent outcome, which is what unlocks Continue
/// while the directory has entries (the flow's mandatory rule). With an
/// empty directory the surface is informational and the step skippable.
struct OnboardingModerationContent: View {
    let onboarding: OnboardingFlow
    @State private var flow: ModerationConsentFlow

    init(
        onboarding: OnboardingFlow,
        makeConsentFlow: @MainActor (ModerationConsentFlow.Mode) -> ModerationConsentFlow
    ) {
        self.onboarding = onboarding
        _flow = State(initialValue: makeConsentFlow(.onboarding))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header suppressed: the scaffold above already reads
            // "Reports & safety" and explains what an authority does.
            // The step's primary is the signature — the review drops its
            // own sign button.
            ModerationConsentContent(flow: flow, showsPickerHeader: false, hostOwnsSigning: true)
                // The content carries the Settings pages' own
                // horizontal insets; pull them back to the scaffold's.
                .padding(.horizontal, -16)
        }
            .task { flow.start() }
            .onDisappear {
                flow.stop()
                onboarding.primaryOverride = nil
            }
            .onChange(of: flow.state.step, initial: true) { _, step in
                // The scaffold's primary signs while terms are on screen;
                // anywhere else (picking, signing, signed) it is its
                // usual gated self.
                if step == .reviewingManifest, onboarding.step == .moderation {
                    onboarding.primaryOverride = { [flow] in flow.tappedAgree() }
                } else {
                    onboarding.primaryOverride = nil
                }
                if step == .done {
                    onboarding.recordOutcome(.consented(
                        componentId: flow.state.selectedListing?.componentId
                    ))
                    // Signing was the step's last act: let the seal
                    // land, then move on without a second tap.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(800))
                        if onboarding.step == .moderation {
                            onboarding.advance()
                        }
                    }
                }
            }
            // A restarted walk (Settings → Restart Onboarding) arrives
            // here with a mandate already active. Standing consent
            // satisfies the step as-is — re-consent is only for
            // changing authority (the pick → review → sign path above,
            // which overwrites this outcome when taken). First runs
            // are untouched: no mandate, no currentAuthorityId.
            .onChange(of: flow.state.currentAuthorityId) { _, current in
                guard let current,
                      onboarding.outcomes[.moderation] == nil
                else { return }
                onboarding.recordOutcome(.consented(componentId: current))
            }
    }
}

// MARK: - Recovery phrase

/// "Save your recovery phrase" — the backup walk, promoted from the
/// old Done-step footnote to a real step. The reveal itself runs the
/// SAME `RecoveryPhraseBackupFlow` Settings uses (biometric gate,
/// scene-phase obscuring, verify quiz), presented as a sheet.
///
/// The step's primary ("I've written it down") stays disabled until an
/// outcome is recorded (`OnboardingFlow.requiresOutcomeToAdvance`) —
/// and the outcome is recorded when the phrase is actually REVEALED,
/// so the button can't assert something the user never saw. "Remind me
/// later" (the step's skip) is the honest escape and keeps the
/// Settings nudge behavior.
struct OnboardingRecoveryContent: View {
    let onboarding: OnboardingFlow
    private let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    /// Created fresh on every presentation and released on dismiss —
    /// the flow holds the plaintext phrase once revealed, so it must
    /// not outlive the sheet: a retained `.reveal` step would let
    /// "View it again" re-show the words without the biometric gate.
    /// Every entry starts at Intro and re-authenticates.
    @State private var flow: RecoveryPhraseBackupFlow?
    @State private var showBackup = false

    /// Derived from the flow, never view-local — the step content is
    /// rebuilt on every navigation, and the status card must not
    /// reset to "Not backed up yet" after Back from Done (the same
    /// hoisting `servicesChoice` got).
    private var sawPhrase: Bool { onboarding.recoveryBackupState != .none }
    private var backedUp: Bool { onboarding.recoveryBackupState == .verified }

    init(
        onboarding: OnboardingFlow,
        makeBackupFlow: @escaping @MainActor () -> RecoveryPhraseBackupFlow
    ) {
        self.onboarding = onboarding
        self.makeBackupFlow = makeBackupFlow
    }

    var body: some View {
        // The recovery step's mirror of the identity step: one symbol,
        // centred by the scaffold, its state badged on the same corner
        // at the same size. A life preserver — the way back if this
        // iPhone is lost — and tapping it opens the words.
        Button {
            flow = makeBackupFlow()
            showBackup = true
        } label: {
            Image(systemName: "lifepreserver.fill")
                .font(.system(size: 64, weight: .semibold))
                .frame(width: 140, height: 140)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(backedUp ? OnymTokens.green : OnymAccent.blue.color)
        .accessibilityLabel(Text(sawPhrase || backedUp ? "View it again" : "Reveal my recovery phrase"))
        .accessibilityHint(Text(statusSubtitle))
        .accessibilityIdentifier("onboarding.recoveryPhrase.reveal") // onym:allow-secret-read — step name, not the phrase
        // Outside the button's label so it stays its own element:
        // what to do next, then that it's done.
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: badgeSymbol)
                .font(.system(size: 40))
                .foregroundStyle(OnymTokens.onAccent, badgeColor)
                .background(OnymTokens.surface, in: Circle())
                .offset(x: 6, y: 6)
                .animation(.spring(duration: 0.35), value: onboarding.recoveryBackupState)
                .allowsHitTesting(false)
                .accessibilityLabel(Text(backedUp ? "Backed up" : (sawPhrase ? "Revealed — write it down" : "Not backed up yet")))
                .accessibilityIdentifier("onboarding.recoveryPhrase.status") // onym:allow-secret-read — step name, not the phrase
        }
        .sheet(isPresented: $showBackup, onDismiss: {
            // stop() breaks the snapshot task's self-retain (dropping
            // the reference alone would leak an immortal flow holding
            // the plaintext phrase) and scrubs back to Intro; nilling
            // then releases our reference. The view's own onDisappear
            // also stops — this is the belt to that suspender.
            flow?.stop()
            flow = nil
        }) {
            if let flow {
                RecoveryPhraseBackupView(flow: flow)
            }
        }
        .onChange(of: flow?.step) { old, step in
            // recordOutcome writes to the flow's CURRENT step — same
            // async-callback hazard OnboardingIdentityContent guards
            // against; refuse to record from anywhere else.
            guard onboarding.step == .recoveryPhrase else { return } // onym:allow-secret-read — step name, not the phrase
            // The reveal is what makes "I've written it down" honest —
            // record the outcome (unlocking the step's primary) the
            // moment the words are actually on screen. The backup
            // state never downgrades: a verified backup stays
            // verified across re-reveals.
            if case .reveal(_, true)? = step {
                if onboarding.recoveryBackupState == .none {
                    onboarding.recoveryBackupState = .revealed
                }
                onboarding.recordOutcome(.consented(componentId: nil))
            }
            if case .done? = step {
                onboarding.recoveryBackupState = .verified
                onboarding.recordOutcome(.consented(componentId: nil))
            }
            // The backup flow's DoneScreen "Done" resets it to .intro
            // (a Settings-era loop) — in onboarding that must dismiss
            // the sheet, not strand the user back at the intro.
            if case .done? = old, case .intro? = step {
                showBackup = false
            }
        }
    }

    /// Before: an eye — look at your words. Seen: a pencil — write
    /// them down. Verified: the identity step's green check.
    private var badgeSymbol: String {
        if backedUp { return "checkmark.circle.fill" }
        if sawPhrase { return "pencil.circle.fill" }
        return "eye.circle.fill"
    }

    private var badgeColor: Color {
        if backedUp { return OnymTokens.green }
        if sawPhrase { return OnymTile.amber }
        return OnymAccent.blue.color
    }

    private var statusSubtitle: LocalizedStringKey {
        if backedUp {
            return "You revealed and verified your phrase. Keep it somewhere safe — off screenshots and out of chats."
        }
        if sawPhrase {
            return "You've seen the 12 words. Verifying a few of them makes sure your copy is right."
        }
        return "Reveal the 12 words, write them down, then verify a few of them. Takes about a minute."
    }
}

/// "Back up again" from the Done step's recovery sheet: the SAME
/// `RecoveryPhraseBackupFlow` the recovery step runs (biometric gate,
/// reveal, verify quiz), with the same lifecycle — a fresh flow per
/// presentation, stopped and released on dismiss so the plaintext
/// phrase never outlives the sheet. Progress lands on the onboarding
/// flow's `recoveryBackupState`, which never downgrades, so the
/// review's tile turns ✓ the moment the quiz passes.
struct OnboardingRecoveryBackupButton: View {
    let onboarding: OnboardingFlow
    let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    @State private var flow: RecoveryPhraseBackupFlow?
    @State private var showBackup = false

    var body: some View {
        Button {
            flow = makeBackupFlow()
            showBackup = true
        } label: {
            Image(systemName: onboarding.recoveryBackupState == .none ? "eye.fill" : "arrow.clockwise")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 120, height: 40)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text(onboarding.recoveryBackupState == .none
            ? "Reveal my recovery phrase"
            : "Back up again"))
        .accessibilityIdentifier("onboarding.done.backup_again")
        .sheet(isPresented: $showBackup, onDismiss: {
            flow?.stop()
            flow = nil
        }) {
            if let flow {
                RecoveryPhraseBackupView(flow: flow)
            }
        }
        .onChange(of: flow?.step) { old, step in
            if case .reveal(_, true)? = step, onboarding.recoveryBackupState == .none {
                onboarding.recoveryBackupState = .revealed
            }
            if case .done? = step {
                onboarding.recoveryBackupState = .verified
            }
            // The flow's DoneScreen "Done" loops back to .intro — here
            // that means the walk is over: close the sheet.
            if case .done? = old, case .intro? = step {
                showBackup = false
            }
        }
    }
}

// MARK: - Done

/// One summary row on the Done step: which seat, what was chosen, and
/// the identifying detail (endpoint URL / key fingerprint / manifest
/// hash) so the summary is checkable, not just reassuring. `trailing`
/// carries the design's count/state text ("2 services", "Agreed");
/// `symbol` draws the seat's icon.
struct OnboardingSummaryRow: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String?
    var symbol: String = "circle"
    var trailing: String?
    /// Whether the seat has something in it — badges the Done grid's
    /// icon, now that the value text isn't on screen to say so.
    var isSet: Bool = true
}

/// The review: everything the walk set up or agreed to, as tiles in
/// balanced rows — up to three a row, each row centred, so any count
/// reads as one symmetric block under the scaffold's seal. Every tile
/// is one size, badged ✓ (agreed / configured), ✎ (started, not done)
/// or – (left empty). Tapping a tile opens what it stands for, in
/// words: the chosen name and the checkable detail behind it (URL, key
/// fingerprint, manifest hash).
struct OnboardingDoneContent: View {
    /// Read for the recovery tile's badge — a user who revealed and
    /// verified must not be told to back it up — and written by the
    /// backup the tile's sheet can run again.
    let onboarding: OnboardingFlow
    let makeBackupFlow: @MainActor () -> RecoveryPhraseBackupFlow
    let loadSummary: @MainActor () async -> [OnboardingSummaryRow]
    @State private var rows: [OnboardingSummaryRow] = []
    @State private var reading: Tile?

    /// One reviewable thing — a seat from the summary, or the phrase.
    struct Tile: Identifiable {
        enum Status { case done, pending, empty }

        let id: String
        let symbol: String
        let status: Status
        let title: String
        let value: String
        let detail: String?
        let trailing: String?
    }

    private static let perRow = 3

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Array(tileRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 16) {
                    ForEach(row) { tile in
                        tileButton(tile)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.done.summary")
        .task { rows = await loadSummary() }
        .sheet(item: $reading) { tile in
            // Looked up live, not the tapped snapshot: a backup run from
            // this sheet must flip it to ✓ while it is still open.
            detailSheet(tiles.first { $0.id == tile.id } ?? tile)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var tiles: [Tile] {
        rows.map { row in
            Tile(
                id: row.id,
                symbol: row.symbol,
                status: row.isSet ? .done : .empty,
                title: row.title,
                value: row.value,
                detail: row.detail,
                trailing: row.trailing
            )
        } + [recoveryTile]
    }

    private var recoveryTile: Tile {
        switch onboarding.recoveryBackupState {
        case .verified:
            return Tile(id: "recoveryPhrase", symbol: "lifepreserver.fill", status: .done,
                        title: String(localized: "Recovery phrase"),
                        value: String(localized: "Backed up"),
                        detail: nil, trailing: nil)
        case .revealed:
            return Tile(id: "recoveryPhrase", symbol: "lifepreserver.fill", status: .pending,
                        title: String(localized: "Finish verifying your recovery phrase"),
                        value: String(localized: "You've seen the 12 words. Verify a few of them from Settings → Back Up Recovery Phrase to make sure your copy is right."),
                        detail: nil, trailing: nil)
        case .none:
            return Tile(id: "recoveryPhrase", symbol: "lifepreserver.fill", status: .empty,
                        title: String(localized: "Back up your recovery phrase"),
                        value: String(localized: "Your identity key was created on this device and exists nowhere else. Back it up from Settings → Back Up Recovery Phrase so you can recover your account."),
                        detail: nil, trailing: nil)
        }
    }

    /// Balanced rows: 5 tiles are 3 + 2, 4 are 2 + 2 — never a full
    /// row over a lone straggler when an even split exists.
    private var tileRows: [[Tile]] {
        let all = tiles
        guard !all.isEmpty else { return [] }
        let rowCount = (all.count + Self.perRow - 1) / Self.perRow
        let base = all.count / rowCount
        var extra = all.count % rowCount
        var out: [[Tile]] = []
        var index = 0
        for _ in 0..<rowCount {
            let size = base + (extra > 0 ? 1 : 0)
            if extra > 0 { extra -= 1 }
            out.append(Array(all[index..<index + size]))
            index += size
        }
        return out
    }

    private func tileButton(_ tile: Tile) -> some View {
        Button {
            reading = tile
        } label: {
            Image(systemName: tile.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(tile.status == .empty ? OnymTokens.text3 : OnymAccent.blue.color)
                .frame(width: 80, height: 80)
                .background(OnymTokens.surface2,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: badgeSymbol(tile.status))
                        .font(.system(size: 22))
                        .foregroundStyle(OnymTokens.onAccent, badgeColor(tile.status))
                        .background(OnymTokens.surface, in: Circle())
                        .offset(x: 6, y: 6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: tile.title))
        .accessibilityValue(Text(verbatim: [tile.value, tile.trailing].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text("Shows what was agreed"))
        .accessibilityIdentifier(tile.id == "recoveryPhrase"
            ? "onboarding.done.backup_nudge"
            : "onboarding.done.tile.\(tile.id)")
    }

    /// What the tile stands for, in words — the one place this step
    /// spells anything out, and only when asked.
    private func detailSheet(_ tile: Tile) -> some View {
        VStack(spacing: 14) {
            Image(systemName: tile.symbol)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(tile.status == .empty ? OnymTokens.text3 : OnymAccent.blue.color)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: badgeSymbol(tile.status))
                        .font(.system(size: 20))
                        .foregroundStyle(OnymTokens.onAccent, badgeColor(tile.status))
                        .offset(x: 8, y: 8)
                }
                .padding(.top, 28)
                .accessibilityHidden(true)
            Text(verbatim: tile.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(OnymTokens.text)
                .multilineTextAlignment(.center)
            Text(verbatim: tile.value)
                .font(.system(size: 15))
                .foregroundStyle(OnymTokens.text2)
                .multilineTextAlignment(.center)
            if let trailing = tile.trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnymTokens.green)
            }
            if let detail = tile.detail {
                Text(verbatim: detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OnymTokens.text3)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            // The phrase isn't only reported on: back it up from here,
            // first time or again — the same walk the recovery step runs.
            if tile.id == "recoveryPhrase" {
                OnboardingRecoveryBackupButton(
                    onboarding: onboarding,
                    makeBackupFlow: makeBackupFlow
                )
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("onboarding.done.detail")
    }

    private func badgeSymbol(_ status: Tile.Status) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .pending: return "pencil.circle.fill"
        case .empty: return "minus.circle.fill"
        }
    }

    private func badgeColor(_ status: Tile.Status) -> Color {
        switch status {
        case .done: return OnymTokens.green
        case .pending: return OnymTile.amber
        case .empty: return OnymTokens.text3
        }
    }
}
