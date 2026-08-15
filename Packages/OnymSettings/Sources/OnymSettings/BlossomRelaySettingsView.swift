import SwiftUI
import OnymDesign
import OnymDiscovery

/// Settings → Transport → Blossom Relays. Lists configured Blossom
/// media servers, lets the user add a custom URL or remove any entry,
/// and surfaces a "Restore default" affordance that re-installs the
/// Onym Official seed. Mirrors `NostrRelaySettingsView`.
///
/// Changes apply immediately — the Blossom client re-reads the first
/// configured server per upload/download, so the next media operation
/// targets whatever is configured right now.
struct BlossomRelaySettingsView: View {
    @State private var flow: BlossomRelaySettingsFlow
    /// The catalog entry whose consent sheet is presented, if any.
    @State private var consentEntry: AttributedCatalogEntry?

    init(flow: BlossomRelaySettingsFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Blossom Relays")

                SettingsSectionLabel(
                    "CONFIGURED · \(flow.state.snapshot.endpoints.count)"
                )
                configuredCard

                DiscoveryCatalogSection(
                    entries: flow.catalogEntries,
                    activeConsent: { flow.activeConsent(for: $0) },
                    consentedOffer: { flow.consentedOffer(for: $0) },
                    tileSymbol: "photo.on.rectangle.angled",
                    accessibilityPrefix: "blossom.catalog",
                    onSelect: { consentEntry = $0 }
                )

                SettingsSectionLabel("ADD CUSTOM URL")
                customURLCard
                SettingsFootnote(
                    "Blossom servers store your media blobs (images, video, voice). Use Onym's, a private deployment, or any Blossom server you trust. URLs must use the https:// (or http://) scheme."
                )

                resetCard
                SettingsFootnote(
                    "Uploads and downloads use the active server. Changes apply to the next upload or download."
                )

                SettingsSectionLabel("SELF-HOST")
                SettingsCard {
                    NavigationLink {
                        SelfHostGuideView.blossom
                    } label: {
                        SettingsRow(
                            title: "Run your own server",
                            subtitle: "Deploy a Blossom server with Docker",
                            last: true
                        ) {
                            SettingsIconTile(symbol: "server.rack",
                                             bg: Color(red: 0.106, green: 0.122, blue: 0.141))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("blossom.run_your_own")
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Blossom Relays")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
        // Paired with `start()` (ModerationSettingsView precedent):
        // the drain retains the flow and the repository stream never
        // finishes on its own, so without this the continuation would
        // accumulate on every visit.
        .onDisappear { flow.stop() }
        // Consent runs as a sheet; on dismiss the catalog badges
        // refresh so a fresh consent shows immediately.
        .sheet(item: $consentEntry, onDismiss: { flow.refreshCatalog() }) { entry in
            if let discovery = flow.discovery {
                ModuleConsentView(flow: discovery.makeConsentFlow(entry))
            }
        }
    }

    // MARK: - Configured list

    @ViewBuilder
    private var configuredCard: some View {
        let endpoints = flow.state.snapshot.endpoints
        if endpoints.isEmpty {
            SettingsCard {
                Text("No servers configured. Media can't be sent or received.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .accessibilityIdentifier("blossom.configured.empty")
            }
        } else {
            // Clipped rounded stack (not SettingsCard) so each row can
            // swipe left to reveal a Delete action masked to the card's
            // corners. Rows carry the card surface so the reveal stays
            // hidden until slid.
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    SwipeToDeleteRow(
                        accessibilityID: "blossom.configured.\(endpoint.url.absoluteString)",
                        onDelete: { flow.tappedRemove(url: endpoint.url) }
                    ) {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                SettingsIconTile(
                                    symbol: "photo.on.rectangle.angled",
                                    bg: SettingsTile.indigo
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(endpoint.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(OnymTokens.text)
                                        // First endpoint is the one
                                        // uploads/downloads target.
                                        if idx == 0 {
                                            Text("ACTIVE")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(OnymAccent.blue.color)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    OnymAccent.blue.color.opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: 4)
                                                )
                                                .accessibilityIdentifier("blossom.active_badge")
                                        }
                                        if endpoint.isDefault {
                                            Text("DEFAULT")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(OnymTokens.text2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    OnymTokens.surface3,
                                                    in: RoundedRectangle(cornerRadius: 4)
                                                )
                                        }
                                    }
                                    Text(endpoint.url.absoluteString)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(OnymTokens.text3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                // Non-first rows can be promoted to
                                // the upload/download target.
                                if idx != 0 {
                                    Button {
                                        flow.tappedMakeActive(url: endpoint.url)
                                    } label: {
                                        Text("Make Active")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(OnymAccent.blue.color)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                OnymTokens.surface3,
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(
                                        "blossom.make_active.\(endpoint.url.absoluteString)"
                                    )
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            if idx != endpoints.count - 1 {
                                Divider()
                                    .background(OnymTokens.hairline)
                                    .padding(.leading, 56)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("blossom.configured.\(endpoint.url.absoluteString)")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Custom URL add

    private var customURLCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(
                        "https://blossom.example.com",
                        text: Binding(
                            get: { flow.state.customDraft },
                            set: { flow.customDraftChanged($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(OnymTokens.text)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        OnymTokens.surface3,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityIdentifier("blossom.add.custom_url_field")
                    Button {
                        flow.tappedAddCustom()
                    } label: {
                        Text("Add")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OnymTokens.onAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                OnymAccent.blue.color,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .accessibilityIdentifier("blossom.add.custom_button")
                }
                if let error = flow.state.customDraftError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(OnymTokens.red)
                        .accessibilityIdentifier("blossom.add.custom_error")
                }
            }
            .padding(14)
        }
    }

    // MARK: - Reset

    private var resetCard: some View {
        SettingsCard {
            Button {
                flow.tappedResetToDefault()
            } label: {
                HStack {
                    SettingsIconTile(
                        symbol: "arrow.counterclockwise",
                        bg: SettingsTile.gray
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore default")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                        Text("Re-install Onym Official as the only server.")
                            .font(.system(size: 12))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("blossom.reset_default")
        }
    }
}
