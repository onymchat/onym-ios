import SwiftUI

/// Root of the Anchors drill-down — Testnet / Mainnet rows. Pushes to
/// `AnchorsNetworkView` for the picked network. Mainnet is disabled
/// while no manifest entries exist for it.
struct AnchorsView: View {
    @State private var flow: AnchorsPickerFlow

    init(flow: AnchorsPickerFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        Form {
            Section {
                ForEach(ContractNetwork.allCases, id: \.self) { network in
                    networkRow(network)
                }
            } footer: {
                Text("Choose the contract version used to anchor on-chain group state. Selection per (network, governance type) pins to new chats; existing chats keep the contract they were created with.")
            }
        }
        .navigationTitle("Anchors")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
    }

    @ViewBuilder
    private func networkRow(_ network: ContractNetwork) -> some View {
        let hasContracts = flow.hasAnyContracts(network: network)
        if hasContracts {
            NavigationLink {
                AnchorsNetworkView(flow: flow, network: network)
            } label: {
                HStack {
                    Text(network.displayName)
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }
            .accessibilityIdentifier("anchors.network.\(network.rawValue)")
        } else {
            HStack {
                Text(network.displayName)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("No contracts yet")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityIdentifier("anchors.network.\(network.rawValue).disabled")
        }
    }
}

/// Second-level drill-down: lists the five governance types for the
/// chosen network. Each row shows the currently resolved release tag
/// + "(latest)" or "(selected)" subtitle.
struct AnchorsNetworkView: View {
    let flow: AnchorsPickerFlow
    let network: ContractNetwork

    var body: some View {
        Form {
            Section {
                ForEach(GovernanceType.allCases, id: \.self) { type in
                    governanceRow(type)
                }
            }
        }
        .navigationTitle(network.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func governanceRow(_ type: GovernanceType) -> some View {
        let key = AnchorSelectionKey(network: network, type: type)
        let binding = flow.binding(for: key)
        let isExplicit = flow.hasExplicitSelection(for: key)

        if let binding {
            NavigationLink {
                AnchorsVersionView(flow: flow, key: key)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(type.displayName)
                            .foregroundStyle(.primary)
                        Text(binding.release + " " + (isExplicit ? "(selected)" : "(latest)"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .accessibilityIdentifier("anchors.type.\(type.rawValue)")
        } else {
            HStack {
                Text(type.displayName)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("No contract")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityIdentifier("anchors.type.\(type.rawValue).disabled")
        }
    }
}

/// Leaf drill-down: lists all releases that have a contract for the
/// (network, type) being picked, newest-first. Tap to select; pop back
/// is automatic. A "Reset to default" row at the bottom clears the
/// explicit selection so the default-to-latest rule kicks in.
struct AnchorsVersionView: View {
    let flow: AnchorsPickerFlow
    let key: AnchorSelectionKey

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                let releases = flow.availableReleases(for: key)
                let selectedTag = flow.binding(for: key)?.release
                ForEach(releases, id: \.release) { release in
                    versionRow(release: release, isSelected: release.release == selectedTag)
                }
            }

            if flow.hasExplicitSelection(for: key) {
                Section {
                    Button("Reset to Default (latest)") {
                        flow.tappedResetToDefault(key: key)
                        dismiss()
                    }
                    .accessibilityIdentifier("anchors.version.reset")
                }
            }
        }
        .navigationTitle("\(key.network.displayName) · \(key.type.displayName)")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func versionRow(release: ContractRelease, isSelected: Bool) -> some View {
        Button {
            flow.tappedVersion(key: key, releaseTag: release.release)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.release)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                    Text(release.publishedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("anchors.version.\(release.release)")
    }
}
