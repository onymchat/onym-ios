import SwiftUI
import OnymDesign
import OnymDiscovery
import OnymFoundation

/// "FROM CATALOG" section shared by the per-seat pickers (relayer,
/// nostr, blossom): discovery-sourced entries with their source label,
/// relationship disclosure, consent state, and — once consented — the
/// accepted offer's badge. Tapping a row hands the entry to the
/// presenting view, which runs `ModuleConsentFlow` as a sheet.
///
/// Renders nothing when `entries` is empty, so pickers without
/// discovery wired (or with an empty aggregate) look exactly as they
/// did before this section existed.
struct DiscoveryCatalogSection: View {
    let entries: [AttributedCatalogEntry]
    /// Cached lookups (computed once per catalog refresh in the flow,
    /// not per row per render — `activeConsent` decodes the whole
    /// consent store and `consentedOffer` a pinned manifest).
    let activeConsent: (AttributedCatalogEntry) -> PinnedConsentRecord?
    let consentedOffer: (AttributedCatalogEntry) -> ServiceOffer?
    let tileSymbol: String
    let accessibilityPrefix: String
    let onSelect: (AttributedCatalogEntry) -> Void

    var body: some View {
        if !entries.isEmpty {
            SettingsSectionLabel("FROM CATALOG")
            SettingsCard {
                ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                    row(entry, last: idx == entries.count - 1)
                }
            }
            SettingsFootnote("Published by the discovery providers you trust. Tapping an entry shows the operator's manifest and terms — nothing is added without your explicit acceptance.")
        }
    }

    private func row(_ entry: AttributedCatalogEntry, last: Bool) -> some View {
        let record = activeConsent(entry)
        return SettingsRow(
            titleText: ModuleConsentFlow.shortComponentId(entry.entry.componentId),
            subtitle: subtitle(for: entry),
            subtitleLineLimit: 2,
            hasChevron: false,
            inset: 56,
            last: last,
            onTap: { onSelect(entry) }
        ) {
            SettingsIconTile(symbol: tileSymbol, bg: SettingsTile.purple)
        } right: {
            HStack(spacing: 4) {
                if let status = entry.entry.status {
                    statusChip(status)
                }
                if let offer = consentedOffer(entry) {
                    OfferBadge(offer: offer)
                }
                consentChip(for: entry, record: record)
            }
        }
        .accessibilityIdentifier("\(accessibilityPrefix).\(entry.id)")
    }

    /// §4.2 disclosed warning/review status: rendered distinctly, in
    /// text — the field exists precisely so a warned entry never
    /// renders indistinguishable from a clean one.
    private func statusChip(_ status: EntryStatus) -> some View {
        SettingsChip(
            text: (status.state == "warning"
                ? String(localized: "WARNING")
                : String(localized: "UNDER REVIEW")).uppercased(),
            fg: SettingsTile.amber,
            bg: SettingsTile.amber.opacity(0.15)
        )
    }

    /// Source + relationship disclosure, in text (not color) so the
    /// disclosure survives every rendering.
    private func subtitle(for entry: AttributedCatalogEntry) -> String {
        String(localized: "Listed by \(entry.source.sourceLabel) — \(ModuleConsentView.disclosureText(entry.source.relationship))")
    }

    /// Consent state relative to the exact digest the catalog pins:
    /// same hash → consented; older consent for the component → the
    /// published terms changed; none → not yet reviewed.
    @ViewBuilder
    private func consentChip(for entry: AttributedCatalogEntry, record: PinnedConsentRecord?) -> some View {
        if let record, record.manifestHash == entry.entry.manifest.digest {
            SettingsChip(text: String(localized: "CONSENTED").uppercased(),
                         fg: OnymTokens.green, bg: OnymTokens.green.opacity(0.15))
        } else if record != nil {
            SettingsChip(text: String(localized: "TERMS CHANGED").uppercased(),
                         fg: SettingsTile.amber, bg: SettingsTile.amber.opacity(0.15))
        } else {
            SettingsChip(text: String(localized: "REVIEW").uppercased(),
                         fg: SettingsTile.gray, bg: SettingsTile.gray.opacity(0.15))
        }
    }

}
