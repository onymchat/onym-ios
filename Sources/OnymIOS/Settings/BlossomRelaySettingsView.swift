import SwiftUI

/// Settings → Transport → Blossom Relays. Lists configured Blossom
/// media servers, lets the user add a custom URL or remove any entry,
/// and surfaces a "Restore default" affordance that re-installs the
/// Onym Official seed. Mirrors `NostrRelaySettingsView`.
///
/// V1 limitation: changes apply on the next app launch — the Blossom
/// client's base URL is chosen once at boot (the first configured
/// server). A footnote at the bottom surfaces this.
struct BlossomRelaySettingsView: View {
    @State private var flow: BlossomRelaySettingsFlow

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

                SettingsSectionLabel("ADD CUSTOM URL")
                customURLCard
                SettingsFootnote(
                    "Blossom servers store your media blobs (images, video, voice). Use Onym's, a private deployment, or any Blossom server you trust. URLs must use the https:// (or http://) scheme."
                )

                resetCard
                SettingsFootnote(
                    "Changes apply on the next app launch. Uploads target the first configured server."
                )
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Blossom Relays")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
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
