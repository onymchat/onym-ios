import SwiftUI
import OnymDesign
import OnymDiscovery

/// Settings → Transport → Nostr Relays. Lists configured Nostr
/// WebSocket endpoints, lets the user add a custom URL or remove
/// any entry, and surfaces a "Restore default" affordance that
/// re-installs the Onym Official seed.
///
/// V1 limitation: changes apply on the next app launch — the inbox
/// transport reads endpoints once at boot. A footnote at the bottom
/// of the screen surfaces this. Live re-connect lands when WebSocket
/// reconnect-on-config-change is wired in a follow-up.
struct NostrRelaySettingsView: View {
    @State private var flow: NostrRelaySettingsFlow
    /// The catalog entry whose consent sheet is presented, if any.
    @State private var consentEntry: AttributedCatalogEntry?

    init(flow: NostrRelaySettingsFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle("Nostr Relays")

                SectionLabel(
                    "CONFIGURED · \(flow.state.snapshot.endpoints.count)"
                )
                configuredCard

                DiscoveryCatalogSection(
                    entries: flow.catalogEntries,
                    activeConsent: { flow.activeConsent(for: $0) },
                    consentedOffer: { flow.consentedOffer(for: $0) },
                    tileSymbol: "antenna.radiowaves.left.and.right.circle.fill",
                    accessibilityPrefix: "nostr.catalog",
                    onSelect: { consentEntry = $0 }
                )

                SectionLabel("ADD CUSTOM URL")
                customURLCard
                Footnote(
                    "Use a private deployment, localhost, or any Nostr relay you trust. URLs must use the wss:// (or ws://) scheme."
                )

                resetCard
                Footnote(
                    "Changes apply on the next app launch. The inbox transport reads relays once at boot."
                )

                SectionLabel("SELF-HOST")
                Card {
                    NavigationLink {
                        SelfHostGuideView.nostr
                    } label: {
                        Row(
                            title: "Run your own relay",
                            subtitle: "Deploy a Nostr relay with Docker",
                            last: true
                        ) {
                            IconTile(symbol: "server.rack",
                                             bg: OnymTerminal.surface)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("nostr.run_your_own")
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Nostr Relays")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
        // Paired with `start()` (ModerationSettingsView precedent):
        // the drains retain the flow and the repository streams never
        // finish on their own, so without this the continuations would
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
            Card {
                Text("No relays configured. Inbox transport is offline.")
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .accessibilityIdentifier("nostr.configured.empty")
            }
        } else {
            // Clipped rounded stack (not Card) so each row can
            // swipe left to reveal a Delete action masked to the card's
            // corners. Rows carry the card surface so the reveal stays
            // hidden until slid.
            VStack(spacing: 0) {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    SwipeToDeleteRow(
                        accessibilityID: "nostr.configured.\(endpoint.url.absoluteString)",
                        onDelete: { flow.tappedRemove(url: endpoint.url) }
                    ) {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                IconTile(
                                    symbol: "antenna.radiowaves.left.and.right",
                                    bg: OnymTile.indigo
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(endpoint.name)
                                            .font(OnymType.font(size: 15, weight: .semibold))
                                            .foregroundStyle(OnymTokens.text)
                                        if endpoint.isDefault {
                                            Text("DEFAULT")
                                                .font(OnymType.font(size: 10, weight: .bold))
                                                .foregroundStyle(OnymTokens.text2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    OnymTokens.surface3,
                                                    in: RoundedRectangle(cornerRadius: OnymRadius.chip)
                                                )
                                        }
                                    }
                                    Text(endpoint.url.absoluteString)
                                        .font(OnymType.mono(size: 12))
                                        .foregroundStyle(OnymTokens.text3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
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
                        .accessibilityIdentifier("nostr.configured.\(endpoint.url.absoluteString)")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Custom URL add

    private var customURLCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(
                        "wss://relay.example.com",
                        text: Binding(
                            get: { flow.state.customDraft },
                            set: { flow.customDraftChanged($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(OnymType.mono(size: 14))
                    .foregroundStyle(OnymTokens.text)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        OnymTokens.surface3,
                        in: RoundedRectangle(cornerRadius: OnymRadius.badge)
                    )
                    .accessibilityIdentifier("nostr.add.custom_url_field")
                    Button {
                        flow.tappedAddCustom()
                    } label: {
                        Text("Add")
                            .font(OnymType.font(size: 14, weight: .semibold))
                            .foregroundStyle(OnymTokens.onAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                OnymAccent.blue.color,
                                in: RoundedRectangle(cornerRadius: OnymRadius.badge)
                            )
                    }
                    .accessibilityIdentifier("nostr.add.custom_button")
                }
                if let error = flow.state.customDraftError {
                    Text(error)
                        .font(OnymType.font(size: 12))
                        .foregroundStyle(OnymTokens.red)
                        .accessibilityIdentifier("nostr.add.custom_error")
                }
            }
            .padding(14)
        }
    }

    // MARK: - Reset

    private var resetCard: some View {
        Card {
            Button {
                flow.tappedResetToDefault()
            } label: {
                HStack {
                    IconTile(
                        symbol: "arrow.counterclockwise",
                        bg: OnymTile.gray
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore default")
                            .font(OnymType.font(size: 15, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                        Text("Re-install Onym Official as the only relay.")
                            .font(OnymType.font(size: 12))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nostr.reset_default")
        }
    }
}
