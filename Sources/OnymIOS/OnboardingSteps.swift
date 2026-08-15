import SwiftUI
import OnymChain
import OnymDesign
import OnymDiscovery
import OnymFoundation
import OnymModerationUI
import OnymOnboarding
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
    let loadSummary: @MainActor () async -> [OnboardingSummaryRow]

    func content(for step: OnboardingStep, flow: OnboardingFlow) -> AnyView? {
        switch step {
        case .welcome:
            return AnyView(OnboardingWelcomeContent())
        case .discoveryConfirm:
            return AnyView(OnboardingDiscoveryContent(
                onboarding: flow,
                makeFlow: makeDiscoveryFlow
            ))
        case .messageTransport:
            return AnyView(OnboardingNostrContent(
                onboarding: flow,
                makeFlow: makeNostrFlow,
                picker: nostrPicker
            ))
        case .blobTransport:
            return AnyView(OnboardingBlossomContent(
                onboarding: flow,
                makeFlow: makeBlossomFlow,
                picker: blossomPicker
            ))
        case .notary:
            return AnyView(OnboardingNotaryContent(
                onboarding: flow,
                makeFlow: makeRelayerFlow,
                picker: relayerPicker
            ))
        case .moderation:
            return AnyView(OnboardingModerationContent(
                onboarding: flow,
                makeConsentFlow: makeModerationConsentFlow
            ))
        case .done:
            return AnyView(OnboardingDoneContent(loadSummary: loadSummary))
        }
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

/// One configured-endpoint row (name + badge + URL), shared by the
/// transport steps. The check mark on the first row is the
/// "preselected default" affordance — the seed is already installed,
/// tapping Continue keeps it.
private struct OnboardingEndpointRow: View {
    let name: String
    let url: URL
    let badge: LocalizedStringKey?
    let selected: Bool
    var last: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? OnymAccent.blue.color : OnymTokens.text3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(OnymTokens.text2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OnymTokens.surface3,
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(url.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OnymTokens.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
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

/// Brand framing over the scaffold's "your keys, your services"
/// subtitle. The identity bootstrap stays silent — it already runs in
/// the WindowGroup task; nothing here mentions or blocks on it.
struct OnboardingWelcomeContent: View {
    var body: some View {
        VStack(spacing: 0) {
            OnymMark(size: 88, color: OnymAccent.blue.color, strokeRatio: 0.14)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                row(symbol: "key.fill",
                    text: "Your identity key is created on this device. No account, no phone number.")
                row(symbol: "antenna.radiowaves.left.and.right",
                    text: "The next screens set up the services this app runs on. Each one shows exactly what you're agreeing to before anything is turned on.")
                row(symbol: "gearshape",
                    text: "Nothing is final — every choice can change later in Settings.")
            }
            .padding(16)
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func row(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(OnymAccent.blue.color)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(2)
        }
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
                accessibilityID: "onboarding.discoveryConfirm.unavailable"
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
            .accessibilityIdentifier("onboarding.discoveryConfirm.added")
        }
    }

    @ViewBuilder
    private func idle(_ flow: DiscoverySettingsFlow) -> some View {
        if let status = flow.state.sources.first {
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
            .accessibilityIdentifier("onboarding.discoveryConfirm.source")

            if status.source.pinnedOperatorKeyHex == nil {
                SettingsPrimaryButton("Verify & Confirm") {
                    flow.tappedConfirmSource(providerId: status.source.providerId)
                }
                .padding(.top, 12)
                .accessibilityIdentifier("onboarding.discoveryConfirm.confirm")
            } else {
                Label("Already confirmed — its key is pinned.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(OnymTokens.green)
                    .padding(.top, 12)
                    .accessibilityIdentifier("onboarding.discoveryConfirm.pinned")
            }
        } else {
            OnboardingInfoCard(
                text: "No discovery provider is configured yet. Add your own below, or continue with the built-in defaults.",
                accessibilityID: "onboarding.discoveryConfirm.empty"
            )
        }

        if let error = flow.addError {
            Text(verbatim: error)
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.red)
                .padding(.top, 8)
                .accessibilityIdentifier("onboarding.discoveryConfirm.error")
        }

        addOwn(flow)
    }

    /// "Add your own provider URL" secondary — the same
    /// fetch-then-TOFU path, aimed at a URL the user types.
    @ViewBuilder
    private func addOwn(_ flow: DiscoverySettingsFlow) -> some View {
        @Bindable var flow = flow
        if showAddOwn {
            OnboardingSectionLabel(text: "YOUR OWN PROVIDER")
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
                    .accessibilityIdentifier("onboarding.discoveryConfirm.add_url_field")
                Button {
                    flow.tappedFetchProvider()
                } label: {
                    Text("Fetch Provider")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnymAccent.blue.color)
                }
                .accessibilityIdentifier("onboarding.discoveryConfirm.fetch")
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
            .accessibilityIdentifier("onboarding.discoveryConfirm.add_own")
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
            .accessibilityIdentifier("onboarding.discoveryConfirm.fingerprint")

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

        SettingsPrimaryButton("Pin Key & Confirm") {
            flow.tappedConfirmAdd()
        }
        .padding(.top, 12)
        .accessibilityIdentifier("onboarding.discoveryConfirm.pin")

        Button("Not now") { flow.tappedCancelPreview() }
            .font(.system(size: 14))
            .foregroundStyle(OnymTokens.text2)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .accessibilityIdentifier("onboarding.discoveryConfirm.cancel_preview")
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
            configured

            catalogSection(prefix: "onboarding.messageTransport.catalog")

            OnboardingSectionLabel(text: "ADD CUSTOM URL")
            OnboardingCustomURLField(
                placeholder: "wss://relay.example.com",
                draft: Binding(
                    get: { flow.state.customDraft },
                    set: { flow.customDraftChanged($0) }
                ),
                error: flow.state.customDraftError,
                accessibilityPrefix: "onboarding.messageTransport",
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
                text: "No relay configured yet. Add one below, or skip to use the default.",
                accessibilityID: "onboarding.messageTransport.empty"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    OnboardingEndpointRow(
                        name: endpoint.name,
                        url: endpoint.url,
                        badge: endpoint.isDefault ? "DEFAULT" : nil,
                        selected: idx == 0,
                        last: idx == endpoints.count - 1
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding.messageTransport.configured.\(endpoint.url.absoluteString)")
                }
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func catalogSection(prefix: String) -> some View {
        if !flow.catalogEntries.isEmpty {
            OnboardingSectionLabel(text: "FROM CATALOG")
            DiscoveryCatalogSection(
                entries: flow.catalogEntries,
                activeConsent: { flow.activeConsent(for: $0) },
                consentedOffer: { flow.consentedOffer(for: $0) },
                tileSymbol: "antenna.radiowaves.left.and.right.circle.fill",
                accessibilityPrefix: prefix,
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
            configured

            if !flow.catalogEntries.isEmpty {
                OnboardingSectionLabel(text: "FROM CATALOG")
                DiscoveryCatalogSection(
                    entries: flow.catalogEntries,
                    activeConsent: { flow.activeConsent(for: $0) },
                    consentedOffer: { flow.consentedOffer(for: $0) },
                    tileSymbol: "photo.on.rectangle.angled",
                    accessibilityPrefix: "onboarding.blobTransport.catalog",
                    onSelect: { entry in
                        lastConsentEntry = entry
                        consentEntry = entry
                    }
                )
                .padding(.horizontal, -16)
            }

            OnboardingSectionLabel(text: "ADD CUSTOM URL")
            OnboardingCustomURLField(
                placeholder: "https://blossom.example.com",
                draft: Binding(
                    get: { flow.state.customDraft },
                    set: { flow.customDraftChanged($0) }
                ),
                error: flow.state.customDraftError,
                accessibilityPrefix: "onboarding.blobTransport",
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
                text: "No server configured yet. Add one below, or skip to use the default.",
                accessibilityID: "onboarding.blobTransport.empty"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    OnboardingEndpointRow(
                        name: endpoint.name,
                        url: endpoint.url,
                        // First endpoint is the upload/download target.
                        badge: idx == 0 ? "ACTIVE" : (endpoint.isDefault ? "DEFAULT" : nil),
                        selected: idx == 0,
                        last: idx == endpoints.count - 1
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding.blobTransport.configured.\(endpoint.url.absoluteString)")
                }
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            configured

            OnboardingSectionLabel(text: "FROM PUBLISHED LIST")
            published

            if !flow.catalogEntries.isEmpty {
                OnboardingSectionLabel(text: "FROM CATALOG")
                DiscoveryCatalogSection(
                    entries: flow.catalogEntries,
                    activeConsent: { flow.activeConsent(for: $0) },
                    consentedOffer: { flow.consentedOffer(for: $0) },
                    tileSymbol: "antenna.radiowaves.left.and.right",
                    accessibilityPrefix: "onboarding.notary.catalog",
                    onSelect: { entry in
                        lastConsentEntry = entry
                        consentEntry = entry
                    }
                )
                .padding(.horizontal, -16)
            }

            OnboardingSectionLabel(text: "ADD CUSTOM URL")
            OnboardingCustomURLField(
                placeholder: "https://relayer.example.com",
                draft: Binding(
                    get: { flow.state.customDraft },
                    set: { flow.customDraftChanged($0) }
                ),
                error: flow.state.customDraftError,
                accessibilityPrefix: "onboarding.notary",
                onAdd: {
                    flow.tappedAddCustom()
                    if flow.state.customDraftError == nil {
                        onboarding.recordOutcome(.consented(componentId: nil))
                    }
                }
            )

            Text("Skip to use the published defaults — they're installed automatically once setup finishes.")
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
                text: "No notary chosen yet. Pick one below, or skip to use the published defaults.",
                accessibilityID: "onboarding.notary.empty"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    OnboardingEndpointRow(
                        name: endpoint.name,
                        url: endpoint.url,
                        badge: nil,
                        selected: true,
                        last: idx == endpoints.count - 1
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding.notary.configured.\(endpoint.url.absoluteString)")
                }
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
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
                .accessibilityIdentifier("onboarding.notary.published.fetching")
            case .failed(let message):
                Text(verbatim: message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(OnymTokens.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .accessibilityIdentifier("onboarding.notary.published.failed")
            case .success where unconfigured.isEmpty:
                Text("All published notaries added.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .accessibilityIdentifier("onboarding.notary.published.all_added")
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
                                        SettingsChip(
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
                    .accessibilityIdentifier("onboarding.notary.published.\(endpoint.url.absoluteString)")
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
        ModerationConsentContent(flow: flow)
            // The content carries the Settings pages' own horizontal
            // insets; pull them back to the scaffold's.
            .padding(.horizontal, -16)
            .task { flow.start() }
            .onDisappear { flow.stop() }
            .onChange(of: flow.state.step) { _, step in
                if step == .done {
                    onboarding.recordOutcome(.consented(
                        componentId: flow.state.selectedListing?.componentId
                    ))
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

// MARK: - Done

/// One summary row on the Done step: which seat, what was chosen, and
/// the identifying detail (endpoint URL / key fingerprint / manifest
/// hash) so the summary is checkable, not just reassuring.
struct OnboardingSummaryRow: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String?
}

/// Summary of the chosen components + the backup-phrase nudge. The
/// recovery-phrase flow itself stays in Settings (it takes biometrics
/// and its own confirmation walk — not something to inline at the end
/// of onboarding).
struct OnboardingDoneContent: View {
    let loadSummary: @MainActor () async -> [OnboardingSummaryRow]
    @State private var rows: [OnboardingSummaryRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: row.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(OnymTokens.text2)
                                Spacer()
                                Text(verbatim: row.value)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(OnymTokens.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if let detail = row.detail {
                                Text(verbatim: detail)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(OnymTokens.text3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if idx != rows.count - 1 {
                            Divider()
                                .background(OnymTokens.hairline)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .background(OnymTokens.surface2,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding.done.summary")

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SettingsTile.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Back up your recovery phrase")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnymTokens.text)
                    Text("Your identity key was created on this device and exists nowhere else. Back it up from Settings → Back Up Recovery Phrase so you can recover your account.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(OnymTokens.text2)
                        .lineSpacing(2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsTile.amber.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 12)
            .accessibilityIdentifier("onboarding.done.backup_nudge")
        }
        .task { rows = await loadSummary() }
    }
}
