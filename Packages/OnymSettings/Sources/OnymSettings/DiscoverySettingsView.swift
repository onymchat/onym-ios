import SwiftUI
import OnymDesign
import OnymDiscovery

/// Settings → Discovery Providers. Lists the user's configured
/// discovery sources with per-source status (fetching / ok / failed /
/// integrity warning), the pinned operator key fingerprint, and how
/// many verified catalog entries each contributes. Swipe a row to
/// remove (behind a confirmation — removal is permanent by design),
/// or add a new provider by manifest URL through the TOFU sheet.
struct DiscoverySettingsView: View {
    @State private var flow: DiscoverySettingsFlow
    @State private var showAddSheet = false
    /// The providerId pending the remove confirmation, if any.
    @State private var pendingRemoval: DiscoverySourceStatus?

    init(flow: DiscoverySettingsFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle("Discovery")

                SectionLabel("PROVIDERS · \(flow.state.sources.count)")
                sourcesCard
                Footnote("Providers publish signed catalogs of relays and services this app can adopt. Every catalog is verified against the operator key you pinned when you added the provider.")

                SectionLabel("ADD")
                Card {
                    Row(
                        title: "Add Discovery Provider",
                        subtitle: "Fetch a provider manifest by URL",
                        hasChevron: false,
                        last: true,
                        onTap: { showAddSheet = true }
                    ) {
                        Circle().fill(OnymAccent.blue.color)
                            .frame(width: 30, height: 30)
                            .overlay(Image(systemName: "plus")
                                .font(OnymType.font(size: 14, weight: .bold))
                                .foregroundStyle(OnymTokens.onAccent))
                    }
                    .accessibilityIdentifier("settings.discovery.add")
                }
                Footnote("You'll see the provider's operator key fingerprint before anything is trusted. Verify it out-of-band — the fingerprint is pinned on first use.")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Discovery")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await flow.refresh() }
        .task { flow.start() }
        // Paired with `start()` (ModerationSettingsView precedent):
        // the snapshot drain retains the flow and the repository's
        // stream never finishes on its own, so without this the
        // continuation would accumulate on every visit.
        .onDisappear { flow.stop() }
        .sheet(isPresented: $showAddSheet, onDismiss: { flow.resetAdd() }) {
            AddDiscoveryProviderView(flow: flow)
        }
        .alert(
            "Remove this provider?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { status in
            Button("Remove Provider", role: .destructive) {
                flow.tappedRemove(providerId: status.source.providerId)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { status in
            Text("\(status.source.userLabel) and its catalogs will be removed, along with its pinned key. It won't come back automatically — you'd have to add it again and re-verify its fingerprint.")
        }
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesCard: some View {
        let sources = flow.state.sources
        if sources.isEmpty {
            Card {
                Text("No discovery providers configured. Add one below.")
                    .font(OnymType.font(size: 14))
                    .foregroundStyle(OnymTokens.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .accessibilityIdentifier("settings.discovery.empty")
            }
        } else {
            // Clipped rounded stack (not Card) so each row can
            // swipe left to reveal a Delete action masked to the card's
            // corners — same construction as the relayer / nostr lists.
            VStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { idx, status in
                    // One stable identifier per row, on the outermost
                    // row element (the delete affordance derives its
                    // own "<id>.delete") — PR-7's UI-test queries must
                    // never match nested duplicates.
                    SwipeToDeleteRow(
                        accessibilityID: "settings.discovery.source.\(status.source.providerId)",
                        onDelete: { pendingRemoval = status }
                    ) {
                        sourceRow(status, last: idx == sources.count - 1)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.discovery.source.\(status.source.providerId)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: OnymRadius.card, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func sourceRow(_ status: DiscoverySourceStatus, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "antenna.radiowaves.left.and.right", bg: OnymTile.purple)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: status.source.userLabel)
                            .font(OnymType.font(size: 15, weight: .semibold))
                            .foregroundStyle(OnymTokens.text)
                        statusChip(for: status)
                    }
                    Text(status.source.manifestURL.absoluteString)
                        .font(OnymType.mono(size: 12))
                        .foregroundStyle(OnymTokens.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let fingerprint = status.source.operatorKeyFingerprint {
                        Text(verbatim: String(localized: "Key \(fingerprint)"))
                            .font(OnymType.mono(size: 12))
                            .foregroundStyle(OnymTokens.text2)
                    } else {
                        Text("Key not yet confirmed")
                            .font(OnymType.font(size: 12))
                            .foregroundStyle(OnymTokens.text3)
                    }
                    Text(entriesLine(for: status))
                        .font(OnymType.font(size: 12))
                        .foregroundStyle(OnymTokens.text3)
                    // Integrity/completeness notes from the last
                    // refresh: needs-confirmation, skipped catalogs and
                    // entries (result_incomplete), forward-jumps,
                    // policy transitions. The repository computes these
                    // precisely so a partly-skipped or unconfirmed
                    // source never reads as a silently empty one.
                    ForEach(status.notes, id: \.self) { note in
                        Text(verbatim: note)
                            .font(OnymType.font(size: 12))
                            .foregroundStyle(OnymTile.amber)
                            .lineLimit(3)
                    }
                    if let error = status.lastError {
                        Text(verbatim: error)
                            .font(OnymType.font(size: 12))
                            .foregroundStyle(status.lastErrorIsIntegrity ? OnymTokens.red : OnymTokens.text2)
                            .lineLimit(3)
                    }
                    if status.lastError != nil {
                        // Retry path for a FAILED / INTEGRITY source —
                        // relaunching the app must never be the only
                        // way to re-attempt a fetch.
                        Button("Retry") { flow.tappedRefresh() }
                            .font(OnymType.font(size: 13, weight: .semibold))
                            .foregroundStyle(OnymAccent.blue.color)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.discovery.source.\(status.source.providerId).retry")
                    } else if status.source.pinnedOperatorKeyHex == nil {
                        // An UNCONFIRMED source (the seeded default) is
                        // advanced through the same TOFU screen as an
                        // added provider: fetch, show the fingerprint,
                        // pin only on explicit confirm.
                        Button("Confirm…") {
                            flow.tappedConfirmSource(providerId: status.source.providerId)
                            showAddSheet = true
                        }
                        .font(OnymType.font(size: 13, weight: .semibold))
                        .foregroundStyle(OnymAccent.blue.color)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.discovery.source.\(status.source.providerId).confirm")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !last {
                Divider()
                    .background(OnymTokens.hairline)
                    .padding(.leading, 56)
            }
        }
    }

    /// One word of status per source. Integrity findings outrank plain
    /// fetch failures — a failing signature is about the provider, not
    /// the network.
    @ViewBuilder
    private func statusChip(for status: DiscoverySourceStatus) -> some View {
        if status.lastError != nil, status.lastErrorIsIntegrity {
            Chip(text: String(localized: "INTEGRITY").uppercased(),
                         fg: OnymTokens.red, bg: OnymTokens.red.opacity(0.15))
        } else if status.lastError != nil {
            Chip(text: String(localized: "FAILED").uppercased(),
                         fg: OnymTile.amber, bg: OnymTile.amber.opacity(0.15))
        } else if flow.state.fetchStatus == .fetching {
            Chip(text: String(localized: "FETCHING").uppercased(),
                         fg: OnymTile.gray, bg: OnymTile.gray.opacity(0.15))
        } else if status.source.pinnedOperatorKeyHex == nil {
            Chip(text: String(localized: "UNCONFIRMED").uppercased(),
                         fg: OnymTile.gray, bg: OnymTile.gray.opacity(0.15))
        } else {
            Chip(text: String(localized: "OK").uppercased(),
                         fg: OnymTokens.green, bg: OnymTokens.green.opacity(0.15))
        }
    }

    private func entriesLine(for status: DiscoverySourceStatus) -> String {
        DiscoveryEntriesLabel.text(count: flow.entryCount(providerId: status.source.providerId))
    }
}

/// Localized "N catalog entries" line for a source row. Pluralization
/// comes from the app catalog's plural variations for the
/// `%lld catalog entries` key (`Resources/Localizable.xcstrings`) — a
/// real per-locale plural rule, not an English-only `== 1` branch.
/// Deliberately not `^[…](inflect: true)`: that markup had no catalog
/// entry, so lookup fell through to the literal key and the raw
/// inflection markup reached the screen under a language override.
/// Public so the hosted unit tests can pin the rendered forms.
public enum DiscoveryEntriesLabel {
    public static func text(count: Int) -> String {
        String(localized: "\(count) catalog entries")
    }
}
