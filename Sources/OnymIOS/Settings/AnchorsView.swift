import SwiftUI

/// Settings → Anchors. Reskinned to the Onym design — three-level
/// drill-down (Network → Governance → Version), plus two new entry
/// points at the leaf: **Deploy from source** and **Use existing
/// address**. The `AnchorsPickerFlow` machinery is unchanged; this
/// only swaps the visual layer and adds the custom-contract surfaces.
struct AnchorsView: View {
    @State private var flow: AnchorsPickerFlow

    init(flow: AnchorsPickerFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsLargeTitle("Anchors")
                SettingsFootnote("Choose the contract version used to anchor on-chain group state. Selection per (network, governance type) pins to new chats; existing chats keep the contract they were created with.")

                SettingsSectionLabel("NETWORK")
                SettingsCard {
                    let nets = ContractNetwork.allCases
                    ForEach(Array(nets.enumerated()), id: \.element.self) { idx, net in
                        networkRow(net, last: idx == nets.count - 1)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Anchors")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
    }

    @ViewBuilder
    private func networkRow(_ network: ContractNetwork, last: Bool) -> some View {
        let hasContracts = flow.hasAnyContracts(network: network)
        let letter = network == .testnet ? "T" : "M"
        let bg = network == .testnet
            ? (hasContracts ? SettingsTile.green : SettingsTile.gray)
            : SettingsTile.gray

        if hasContracts {
            NavigationLink {
                AnchorsNetworkView(flow: flow, network: network)
            } label: {
                SettingsRow(
                    title: LocalizedStringKey(network.displayName),
                    subtitle: networkSubtitle(network),
                    last: last
                ) {
                    SettingsContentTile(bg: bg) {
                        Text(letter).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("anchors.network.\(network.rawValue)")
        } else {
            SettingsRow(
                title: LocalizedStringKey(network.displayName),
                subtitle: "No contracts yet",
                hasChevron: false,
                last: last
            ) {
                SettingsContentTile(bg: bg) {
                    Text(letter).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            } right: {
                Text("Soon")
                    .foregroundStyle(OnymTokens.text3)
                    .font(.system(size: 14))
            }
            .accessibilityIdentifier("anchors.network.\(network.rawValue).disabled")
        }
    }

    private func networkSubtitle(_ network: ContractNetwork) -> String {
        let releases = flow.state.manifest.releases.count
        return "\(GovernanceType.allCases.count) governance types · \(releases) release\(releases == 1 ? "" : "s")"
    }
}

// MARK: - Network → Governance type list

struct AnchorsNetworkView: View {
    let flow: AnchorsPickerFlow
    let network: ContractNetwork

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionLabel("GOVERNANCE TYPES")
                SettingsCard {
                    let types = GovernanceType.allCases
                    ForEach(Array(types.enumerated()), id: \.element.self) { idx, type in
                        govRow(type, last: idx == types.count - 1)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle(network.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func govRow(_ type: GovernanceType, last: Bool) -> some View {
        let key = AnchorSelectionKey(network: network, type: type)
        let binding = flow.binding(for: key)
        let isExplicit = flow.hasExplicitSelection(for: key)

        if let binding {
            NavigationLink {
                AnchorsVersionView(flow: flow, key: key)
            } label: {
                SettingsRow(
                    title: LocalizedStringKey(type.displayName),
                    subtitle: "\(binding.release) " + (isExplicit ? "(selected)" : "(latest)"),
                    inset: 56,
                    last: last
                ) {
                    GovernanceTypeTile(type: type)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("anchors.type.\(type.rawValue)")
        } else {
            SettingsRow(
                title: LocalizedStringKey(type.displayName),
                subtitle: "No contract",
                hasChevron: false,
                inset: 56,
                last: last
            ) {
                GovernanceTypeTile(type: type, dimmed: true)
            } right: {
                Text("—")
                    .foregroundStyle(OnymTokens.text3)
                    .font(.system(size: 14))
            }
            .accessibilityIdentifier("anchors.type.\(type.rawValue).disabled")
        }
    }
}

private struct GovernanceTypeTile: View {
    let type: GovernanceType
    var dimmed: Bool = false

    private var palette: (bg: Color, fg: Color) {
        switch type {
        case .anarchy:   return (SettingsTile.orange.opacity(0.16), Color(red: 0.82, green: 0.29, blue: 0))
        case .democracy: return (OnymTokens.green.opacity(0.16),    Color(red: 0.10, green: 0.51, blue: 0.28))
        case .oligarchy: return (SettingsTile.indigo.opacity(0.16), Color(red: 0.24, green: 0.24, blue: 0.79))
        case .oneonone:  return (OnymAccent.blue.color.opacity(0.16), OnymAccent.blue.color)
        case .tyranny:   return (OnymTokens.red.opacity(0.16),      OnymTokens.red)
        }
    }

    private var letters: String {
        switch type {
        case .anarchy:   return "AN"
        case .democracy: return "DE"
        case .oligarchy: return "OL"
        case .oneonone:  return "1\u{00B7}1"
        case .tyranny:   return "TY"
        }
    }

    var body: some View {
        let p = palette
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(dimmed ? OnymTokens.surface3 : p.bg)
            .frame(width: 30, height: 30)
            .overlay(
                Text(letters)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(dimmed ? OnymTokens.text3 : p.fg)
            )
    }
}

// MARK: - Version list (with custom contract entry points)

struct AnchorsVersionView: View {
    let flow: AnchorsPickerFlow
    let key: AnchorSelectionKey

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionLabel("CONTRACT VERSION")
                SettingsCard {
                    let releases = flow.availableReleases(for: key)
                    let selectedTag = flow.binding(for: key)?.release
                    let latestTag = releases.first?.release
                    ForEach(Array(releases.enumerated()), id: \.element.release) { idx, release in
                        versionRow(
                            release: release,
                            isSelected: release.release == selectedTag,
                            isLatest: release.release == latestTag,
                            last: idx == releases.count - 1
                        )
                    }
                }
                SettingsFootnote("Tap a version to view the contract, source code, and audit report.")

                SettingsSectionLabel("CUSTOM")
                SettingsCard {
                    NavigationLink {
                        DeployContractView(key: key)
                    } label: {
                        SettingsRow(
                            title: "Deploy from source",
                            subtitle: "Build & publish your own contract"
                        ) {
                            SettingsIconTile(symbol: "chevron.left.forwardslash.chevron.right",
                                             bg: OnymTokens.text)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("anchors.deploy_from_source")

                    NavigationLink {
                        UseExistingContractView(key: key)
                    } label: {
                        SettingsRow(
                            title: "Use existing address",
                            subtitle: "Point to a deployed contract",
                            last: true
                        ) {
                            SettingsIconTile(symbol: "shippingbox.fill",
                                             bg: SettingsTile.indigo)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("anchors.use_existing")
                }
                SettingsFootnote("Onym only ships audited (or pending-audit) contracts. If you’ve forked or deployed your own, point new chats at it here. Existing chats keep the contract they were created with.")

                if flow.hasExplicitSelection(for: key) {
                    SettingsSectionLabel("RESET")
                    SettingsCard {
                        SettingsRow(
                            title: "Reset to default (latest)",
                            titleColor: OnymAccent.blue.color,
                            hasChevron: false,
                            inset: 16,
                            last: true,
                            onTap: {
                                flow.tappedResetToDefault(key: key)
                                dismiss()
                            }
                        ) {
                            EmptyView()
                        }
                        .accessibilityIdentifier("anchors.version.reset")
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "\(key.network.displayName) · \(key.type.displayName)"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func versionRow(release: ContractRelease, isSelected: Bool, isLatest: Bool, last: Bool) -> some View {
        NavigationLink {
            ContractDetailView(flow: flow, key: key, release: release)
        } label: {
            SettingsRow(
                title: LocalizedStringKey(release.release),
                titleMono: true,
                subtitle: release.publishedAt.formatted(date: .abbreviated, time: .omitted),
                inset: 16,
                last: last
            ) {
                EmptyView()
            } right: {
                HStack(spacing: 8) {
                    if isLatest {
                        Text("LATEST")
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(OnymTokens.green.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(OnymTokens.green)
                    }
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(OnymAccent.blue.color)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("anchors.version.\(release.release)")
    }
}
