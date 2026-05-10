import SwiftUI

/// Settings → Relayer. Reskinned to the Onym design — segmented
/// strategy toggle, configured-relayers card with star-to-promote and
/// network chips, dedicated custom-URL section, plus a dark "Run your
/// own relayer" CTA that pushes the explainer screen linking to
/// `github.com/onymchat/onym-relayer`.
///
/// All flow integrations remain intact (`RelayerSettingsFlow` drives
/// every intent); only the visual layer changed. Accessibility
/// identifiers are preserved so existing UI tests still bind.
struct RelayerSettingsView: View {
    @State private var flow: RelayerSettingsFlow

    init(flow: RelayerSettingsFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Relayer")

                strategyToggle

                SettingsSectionLabel("CONFIGURED · \(flow.state.snapshot.configuration.endpoints.count)")
                configuredCard

                SettingsSectionLabel("ADD FROM PUBLISHED LIST")
                publishedCard
                SettingsFootnote("Published by the onym-relayer project. Tap to add.")

                SettingsSectionLabel("ADD CUSTOM URL")
                customURLCard
                SettingsFootnote("Use a private deployment, localhost, or any relayer not in the published list.")

                runYourOwnCTA
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Relayer")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
    }

    // MARK: - Strategy toggle (segmented capsule)

    private var strategyToggle: some View {
        let current = flow.state.snapshot.configuration.strategy
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(RelayerStrategy.allCases, id: \.self) { s in
                    Button { flow.tappedStrategy(s) } label: {
                        Text(s.displayName)
                            .font(.system(size: 13.5,
                                          weight: current == s ? .semibold : .medium))
                            .foregroundStyle(OnymTokens.text)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(current == s
                                        ? AnyShapeStyle(OnymTokens.surface2)
                                        : AnyShapeStyle(Color.clear),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("relayer.strategy.\(s.rawValue)")
                    // Plain Buttons don't expose `.isSelected` like a
                    // SwiftUI `Picker` would — XCUI's `isSelected` reads
                    // this trait, so set it on the active segment.
                    .accessibilityAddTraits(current == s ? .isSelected : [])
                }
            }
            .padding(2)
            .background(OnymTokens.surface3,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 16)
            .accessibilityIdentifier("relayer.strategy.picker")

            Text(strategyFooter(current))
                .font(.system(size: 12.5))
                .foregroundStyle(OnymTokens.text2)
                .lineSpacing(2)
                .padding(.horizontal, 20)
                .padding(.top, 10)
        }
    }

    private func strategyFooter(_ strategy: RelayerStrategy) -> LocalizedStringKey {
        switch strategy {
        case .primary:
            return "Always use the primary relayer. If no primary is set, the first configured relayer is used."
        case .random:
            return "Pick a random relayer for each request. Useful for spreading load across redundant deployments."
        }
    }

    // MARK: - Configured

    @ViewBuilder
    private var configuredCard: some View {
        let endpoints = flow.state.snapshot.configuration.endpoints
        if endpoints.isEmpty {
            SettingsCard {
                Text("No relayers configured. Add one below.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 14)
            }
        } else {
            SettingsCard {
                ForEach(Array(endpoints.enumerated()), id: \.element.url) { idx, endpoint in
                    SettingsRow(
                        title: LocalizedStringKey(endpoint.name),
                        subtitle: endpoint.url.absoluteString,
                        subtitleMono: true,
                        hasChevron: false,
                        inset: 56,
                        last: idx == endpoints.count - 1
                    ) {
                        Button { flow.tappedSetPrimary(url: endpoint.url) } label: {
                            Image(systemName: flow.isPrimary(endpoint) ? "star.fill" : "star")
                                .font(.system(size: 17))
                                .foregroundStyle(flow.isPrimary(endpoint) ? SettingsTile.amber : OnymTokens.text3)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("relayer.configured.primary.\(endpoint.url.absoluteString)")
                    } right: {
                        HStack(spacing: 4) {
                            ForEach(endpoint.networks, id: \.self) { net in
                                SettingsChip(
                                    text: net.uppercased(),
                                    fg: chipColor(for: net),
                                    bg: chipColor(for: net).opacity(0.15)
                                )
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("relayer.configured.\(endpoint.url.absoluteString)")
                }
            }
        }
    }

    private func chipColor(for network: String) -> Color {
        switch network {
        case "public":  return OnymTokens.red
        case "testnet": return OnymTokens.green
        default:        return SettingsTile.gray
        }
    }

    // MARK: - Published list

    @ViewBuilder
    private var publishedCard: some View {
        let snapshot = flow.state.snapshot
        let unconfigured = flow.unconfiguredKnownList
        SettingsCard {
            switch snapshot.fetchStatus {
            case .idle:
                fetchingRow
            case .fetching:
                if snapshot.knownList.isEmpty { fetchingRow }
                else { knownList(unconfigured) }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text2)
                    Button("Try Again") { flow.tappedRetryFetch() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OnymAccent.blue.color)
                        .accessibilityIdentifier("relayer.add.known.retry")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            case .success:
                if snapshot.knownList.isEmpty {
                    Text("No published relayers yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .accessibilityIdentifier("relayer.add.known.empty")
                } else if unconfigured.isEmpty {
                    Text("All published relayers added.")
                        .font(.system(size: 14))
                        .foregroundStyle(OnymTokens.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .accessibilityIdentifier("relayer.add.known.all_added")
                } else {
                    knownList(unconfigured)
                }
            }
        }
    }

    private var fetchingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Fetching list…")
                .font(.system(size: 14))
                .foregroundStyle(OnymTokens.text2)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .accessibilityIdentifier("relayer.add.known.fetching")
    }

    @ViewBuilder
    private func knownList(_ unconfigured: [RelayerEndpoint]) -> some View {
        ForEach(Array(unconfigured.enumerated()), id: \.element.url) { idx, endpoint in
            SettingsRow(
                title: LocalizedStringKey(endpoint.name),
                subtitle: endpoint.url.absoluteString,
                subtitleMono: true,
                hasChevron: false,
                inset: 56,
                last: idx == unconfigured.count - 1,
                onTap: { flow.tappedAddKnown(endpoint) }
            ) {
                Circle().fill(OnymAccent.blue.color)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(OnymTokens.onAccent))
            } right: {
                HStack(spacing: 4) {
                    ForEach(endpoint.networks, id: \.self) { net in
                        SettingsChip(
                            text: net.uppercased(),
                            fg: chipColor(for: net),
                            bg: chipColor(for: net).opacity(0.15)
                        )
                    }
                }
            }
            .accessibilityIdentifier("relayer.add.known.\(endpoint.url.absoluteString)")
        }
    }

    // MARK: - Custom URL

    private var customURLCard: some View {
        SettingsCard {
            TextField("https://relayer.example.com",
                      text: Binding(
                        get: { flow.state.customDraft },
                        set: { flow.customDraftChanged($0) }
                      ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(size: 16, design: .monospaced))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .accessibilityIdentifier("relayer.add.custom.field")

            if let error = flow.state.customDraftError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }

            SettingsRowDivider(inset: 16)

            SettingsRow(
                title: "Add Custom URL",
                hasChevron: false,
                inset: 0,
                last: true,
                onTap: { flow.tappedAddCustom() }
            ) {
                Circle().fill(OnymAccent.blue.color)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OnymTokens.onAccent))
            }
            .accessibilityIdentifier("relayer.add.custom.button")
        }
    }

    // MARK: - Run your own relayer CTA

    private var runYourOwnCTA: some View {
        NavigationLink {
            RunYourOwnRelayerView()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run your own relayer")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Deploy onym-relayer from GitHub in 5 minutes")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(18)
            .background(LinearGradient(colors: [Color(red: 0.106, green: 0.122, blue: 0.141),
                                                  Color(red: 0.051, green: 0.067, blue: 0.090)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing),
                         in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 24)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("relayer.run_your_own")
    }
}
