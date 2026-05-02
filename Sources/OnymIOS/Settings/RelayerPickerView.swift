import SwiftUI

/// Picker for the relayer the app uses to anchor on-chain state.
/// Two sections:
///   - "Known relayers" — from the latest GitHub Releases asset of
///     onymchat/onym-relayer. Tap a row to select.
///   - "Custom" — text field for a private deployment / localhost.
///     Tap Save to commit; clears the known-list selection.
struct RelayerPickerView: View {
    @State private var flow: RelayerPickerFlow

    init(flow: RelayerPickerFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        Form {
            Section {
                if flow.state.snapshot.knownList.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Fetching list…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(flow.state.snapshot.knownList) { endpoint in
                        Button {
                            flow.tappedKnownRelayer(endpoint)
                        } label: {
                            knownRow(endpoint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("relayer.known.\(endpoint.url.absoluteString)")
                    }
                }
            } header: {
                Text("Known Relayers")
            } footer: {
                Text("Published by the onym-relayer project. Tap to select.")
            }

            Section {
                TextField("https://relayer.example.com", text: Binding(
                    get: { flow.state.customDraft },
                    set: { flow.customDraftChanged($0) }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("relayer.custom.field")

                if let error = flow.state.customDraftError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button("Save Custom URL") {
                    flow.tappedSaveCustom()
                }
                .accessibilityIdentifier("relayer.custom.save")
            } header: {
                Text("Custom")
            } footer: {
                Text("Use a private deployment, localhost, or any relayer not in the published list.")
            }

            if flow.state.snapshot.selection != nil {
                Section {
                    Button("Clear Selection", role: .destructive) {
                        flow.tappedClearSelection()
                    }
                    .accessibilityIdentifier("relayer.clear")
                }
            }
        }
        .navigationTitle("Relayer")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
    }

    @ViewBuilder
    private func knownRow(_ endpoint: RelayerEndpoint) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name)
                    .foregroundStyle(.primary)
                Text(endpoint.url.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            networkBadge(endpoint.network)
            if isSelected(endpoint) {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func networkBadge(_ network: String) -> some View {
        Text(network.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(network == "public" ? Color.red : Color.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (network == "public" ? Color.red : Color.green).opacity(0.15),
                in: Capsule()
            )
    }

    private func isSelected(_ endpoint: RelayerEndpoint) -> Bool {
        if case .known(let selected) = flow.state.snapshot.selection {
            return selected == endpoint
        }
        return false
    }
}
