import SwiftUI

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

    init(flow: NostrRelaySettingsFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Nostr Relays")

                SettingsSectionLabel(
                    "CONFIGURED · \(flow.state.snapshot.endpoints.count)"
                )
                configuredCard

                SettingsSectionLabel("ADD CUSTOM URL")
                customURLCard
                SettingsFootnote(
                    "Use a private deployment, localhost, or any Nostr relay you trust. URLs must use the wss:// (or ws://) scheme."
                )

                resetCard
                SettingsFootnote(
                    "Changes apply on the next app launch. The inbox transport reads relays once at boot."
                )
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Nostr Relays")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
    }

    // MARK: - Configured list

    @ViewBuilder
    private var configuredCard: some View {
        let endpoints = flow.state.snapshot.endpoints
        SettingsCard {
            if endpoints.isEmpty {
                Text("No relays configured. Inbox transport is offline.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .accessibilityIdentifier("nostr.configured.empty")
            } else {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    HStack(spacing: 12) {
                        SettingsIconTile(
                            symbol: "antenna.radiowaves.left.and.right",
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
                        Button {
                            flow.tappedRemove(url: endpoint.url)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(OnymTokens.red)
                        }
                        .accessibilityLabel("Remove \(endpoint.name)")
                        .accessibilityIdentifier("nostr.configured.remove.\(endpoint.url.absoluteString)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if idx != endpoints.count - 1 {
                        Divider()
                            .background(OnymTokens.hairline)
                            .padding(.leading, 56)
                    }
                }
            }
        }
    }

    // MARK: - Custom URL add

    private var customURLCard: some View {
        SettingsCard {
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
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(OnymTokens.text)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(
                        OnymTokens.surface3,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityIdentifier("nostr.add.custom_url_field")
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
                    .accessibilityIdentifier("nostr.add.custom_button")
                }
                if let error = flow.state.customDraftError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(OnymTokens.red)
                        .accessibilityIdentifier("nostr.add.custom_error")
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
                        Text("Re-install Onym Official as the only relay.")
                            .font(.system(size: 12))
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
