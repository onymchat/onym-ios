import SwiftUI
import OnymDesign
import OnymDiscovery

/// Settings → Backup → Backup Operators. The one surface from which a
/// device-backup operator can be found, read and consented to.
///
/// Deliberately not a list of "configured" operators: the ones already
/// holding a copy live on the Device Backup screen, where they can be
/// enrolled, run and stopped. This screen is the doorway — catalog
/// entries with their source attribution and consent state, each one
/// opening the operator's own signed manifest and terms.
///
/// Consenting here is what makes the Device Backup section exist at
/// all: `BackupSeat.consentedManifests` reads the pinned records this
/// sheet writes, and until one exists there is nothing for that
/// section to show.
struct BackupOperatorSettingsView: View {
    @State private var flow: BackupOperatorSettingsFlow
    /// The catalog entry whose consent sheet is presented, if any.
    @State private var consentEntry: AttributedCatalogEntry?

    init(flow: BackupOperatorSettingsFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle("Backup Operators")

                if flow.catalogEntries.isEmpty {
                    emptyCard
                } else {
                    DiscoveryCatalogSection(
                        entries: flow.catalogEntries,
                        activeConsent: { flow.activeConsent(for: $0) },
                        consentedOffer: { flow.consentedOffer(for: $0) },
                        tileSymbol: "externaldrive.badge.timemachine",
                        accessibilityPrefix: "backup.catalog",
                        onSelect: { consentEntry = $0 }
                    )
                }

                Footnote("A backup operator stores sealed copies of this phone's history. The copy is sealed here, before it leaves — the operator keeps bytes it cannot read, and only your recovery phrase can open them. You can back up to more than one operator, and each one holds its own copy under its own terms.")
            }
            .padding(.bottom, 32)
        }
        .background(OnymTokens.surface.ignoresSafeArea())
        .navigationTitle("Backup Operators")
        .navigationBarTitleDisplayMode(.inline)
        .task { flow.start() }
        // Paired with `start()`, like every other catalog screen: the
        // drain retains the flow and the entries stream never finishes
        // on its own.
        .onDisappear { flow.stop() }
        // Consent runs as a sheet; on dismiss the catalog badges
        // refresh so a fresh consent shows immediately.
        .sheet(item: $consentEntry, onDismiss: { flow.refreshCatalog() }) { entry in
            if let discovery = flow.discovery {
                ModuleConsentView(flow: discovery.makeConsentFlow(entry))
            }
        }
    }

    /// No entries is an ordinary state, not a failure: a build without
    /// the discovery stack, or a set of trusted providers that lists no
    /// backup operator. Say why nothing is on offer rather than
    /// leaving a screen that looks like it is still loading.
    private var emptyCard: some View {
        Card {
            Text("No backup operators are listed by the discovery providers you trust. Add a provider that lists one, and it will appear here.")
                .font(OnymType.font(size: 14))
                .foregroundStyle(OnymTokens.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .accessibilityIdentifier("backup.catalog.empty")
        }
    }
}
