import SwiftUI

/// Settings screen for configuring relayers. Three sections on one
/// screen:
///   - **Strategy** — segmented control: Primary | Random.
///   - **Configured** — list of endpoints the user has added; tap
///     star to mark primary, swipe to delete.
///   - **Add** — published-list rows the user hasn't added yet, plus
///     a custom-URL field.
struct RelayerSettingsView: View {
    @State private var flow: RelayerSettingsFlow

    init(flow: RelayerSettingsFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        Form {
            strategySection
            configuredSection
            addFromKnownSection
            addCustomSection
        }
        .navigationTitle("Relayer")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
    }

    // MARK: - Strategy

    @ViewBuilder
    private var strategySection: some View {
        Section {
            Picker("Strategy", selection: Binding(
                get: { flow.state.snapshot.configuration.strategy },
                set: { flow.tappedStrategy($0) }
            )) {
                ForEach(RelayerStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("relayer.strategy.picker")
        } footer: {
            Text(strategyFooter)
        }
    }

    /// Returns a `LocalizedStringKey` so the literals are auto-extracted
    /// into `Localizable.xcstrings` (a plain `String` would be opaque to
    /// the extractor and `Text(_)` wouldn't localize it).
    private var strategyFooter: LocalizedStringKey {
        switch flow.state.snapshot.configuration.strategy {
        case .primary:
            return "Always use the primary relayer. If no primary is set, the first configured relayer is used."
        case .random:
            return "Pick a random relayer for each request. Useful for spreading load across redundant deployments."
        }
    }

    // MARK: - Configured

    @ViewBuilder
    private var configuredSection: some View {
        Section {
            let endpoints = flow.state.snapshot.configuration.endpoints
            if endpoints.isEmpty {
                Text("No relayers configured. Add one below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(endpoints) { endpoint in
                    configuredRow(endpoint)
                }
                .onDelete { offsets in
                    for offset in offsets {
                        flow.tappedRemove(url: endpoints[offset].url)
                    }
                }
            }
        } header: {
            Text("Configured")
        }
    }

    @ViewBuilder
    private func configuredRow(_ endpoint: RelayerEndpoint) -> some View {
        HStack(spacing: 12) {
            Button {
                flow.tappedSetPrimary(url: endpoint.url)
            } label: {
                Image(systemName: flow.isPrimary(endpoint) ? "star.fill" : "star")
                    .foregroundStyle(flow.isPrimary(endpoint) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("relayer.configured.primary.\(endpoint.url.absoluteString)")

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
            networkBadges(endpoint.networks)
        }
        // `.contain` keeps the inner star Button individually
        // accessible (otherwise SwiftUI flattens the HStack into a
        // single accessibility element that absorbs the inner Button's
        // identifier — caught the hard way by UI tests in PR #22).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("relayer.configured.\(endpoint.url.absoluteString)")
    }

    // MARK: - Add from published list

    @ViewBuilder
    private var addFromKnownSection: some View {
        Section {
            knownSectionContent
        } header: {
            Text("Add from Published List")
        } footer: {
            Text("Published by the onym-relayer project. Tap to add.")
        }
    }

    /// Status-aware content for the published-list section. Gates on
    /// `fetchStatus` (NOT `knownList.isEmpty`) so a failed fetch shows
    /// an actionable error + retry instead of spinning forever, and a
    /// successful fetch with an empty list shows that explicitly.
    @ViewBuilder
    private var knownSectionContent: some View {
        let snapshot = flow.state.snapshot
        let unconfigured = flow.unconfiguredKnownList
        switch snapshot.fetchStatus {
        case .idle:
            // Background fetch hasn't been kicked off yet (or app
            // launched without `.task { repo.start() }`).
            HStack {
                ProgressView()
                Text("Fetching list…").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("relayer.add.known.fetching")

        case .fetching:
            // In flight; show the spinner unless we already have a
            // cached list to display from a previous successful run.
            if snapshot.knownList.isEmpty {
                HStack {
                    ProgressView()
                    Text("Fetching list…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("relayer.add.known.fetching")
            } else {
                knownEndpointsList(unconfigured: unconfigured)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    flow.tappedRetryFetch()
                }
                .accessibilityIdentifier("relayer.add.known.retry")
            }

        case .success:
            if snapshot.knownList.isEmpty {
                Text("No published relayers yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("relayer.add.known.empty")
            } else if unconfigured.isEmpty {
                Text("All published relayers added.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("relayer.add.known.all_added")
            } else {
                knownEndpointsList(unconfigured: unconfigured)
            }
        }
    }

    @ViewBuilder
    private func knownEndpointsList(unconfigured: [RelayerEndpoint]) -> some View {
        ForEach(unconfigured) { endpoint in
            Button {
                flow.tappedAddKnown(endpoint)
            } label: {
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
                    networkBadges(endpoint.networks)
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("relayer.add.known.\(endpoint.url.absoluteString)")
        }
    }

    // MARK: - Custom URL

    @ViewBuilder
    private var addCustomSection: some View {
        Section {
            TextField("https://relayer.example.com", text: Binding(
                get: { flow.state.customDraft },
                set: { flow.customDraftChanged($0) }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("relayer.add.custom.field")

            if let error = flow.state.customDraftError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("Add Custom URL") {
                flow.tappedAddCustom()
            }
            .accessibilityIdentifier("relayer.add.custom.button")
        } header: {
            Text("Add Custom URL")
        } footer: {
            Text("Use a private deployment, localhost, or any relayer not in the published list.")
        }
    }

    // MARK: - Atoms

    /// Render one badge per network the relayer serves. The published
    /// manifest may list multiple networks per endpoint (a single
    /// deployment can serve testnet + mainnet); custom user entries
    /// have a single `"custom"` badge.
    private func networkBadges(_ networks: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(networks, id: \.self) { network in
                Text(network.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeForeground(for: network))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeForeground(for: network).opacity(0.15), in: Capsule())
            }
        }
    }

    private func badgeForeground(for network: String) -> Color {
        switch network {
        case "public": return .red
        case "testnet": return .green
        default: return .gray
        }
    }
}
