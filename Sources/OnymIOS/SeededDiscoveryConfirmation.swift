import Foundation
import OnymDiscovery

/// Programmatic TOFU confirm of the SEEDED default discovery source,
/// run when the user leaves the onboarding services step having
/// accepted the "Recommended setup".
///
/// Why this is a legitimate TOFU site: the recommended card names
/// "Onym Discovery" as part of the setup being accepted, so tapping
/// Continue over it IS the user's explicit trust-on-first-use act for
/// the seeded source — the same decision the hub's Directory seat
/// captures with its "Verify & Confirm" walk, minus the on-screen
/// fingerprint. Nothing is weakened downstream: the manifest is
/// fetched and signature-verified before anything is pinned
/// (`DiscoveryRepository.addSource`), every later refresh verifies
/// against the pinned key, and the pin is refused if the URL serves a
/// different provider than the seeded identity. Out-of-band
/// fingerprint verification remains what the custom path ("Choose
/// services myself" → Directory) is for — this helper never touches a
/// user-added URL, only the source seeded from
/// `DiscoverySource.onymDefault`.
///
/// Without this, the recommended path left the seed unpinned:
/// `DiscoveryRepository` skips unpinned sources on refresh, so the
/// catalog aggregate stayed empty ("SUGGESTED BY YOUR DIRECTORIES"
/// never populated) while the walk presented the directory as active.
enum SeededDiscoveryConfirmation {

    /// Fetch → verify → pin the seeded default source, then refresh it
    /// so its catalogs land in the aggregate.
    ///
    /// Idempotent: a no-op when the source is already pinned (the user
    /// confirmed it through the hub, or a previous fire won), absent
    /// (removed), or the repository runs without it. Failure must not
    /// block the onboarding walk — an offline first run simply leaves
    /// the source unpinned, the Done summary reports "Not confirmed",
    /// and the Settings "Confirm…" affordance stays available.
    static func confirmIfUnpinned(repository: DiscoveryRepository) async {
        let seeded = DiscoverySource.onymDefault
        let state = await repository.currentState()
        guard let status = state.sources.first(where: { $0.id == seeded.providerId }),
              status.source.pinnedOperatorKeyHex == nil
        else { return }
        do {
            // The SEEDED manifest URL only — never a user-typed one.
            let preview = try await repository.addSource(manifestURL: seeded.manifestURL)
            // The URL must still serve the seeded provider identity;
            // anything else is not what the recommended card promised,
            // so it gets no programmatic pin.
            guard preview.providerId == seeded.providerId else { return }
            await repository.confirmAddSource(preview)
            // Targeted refresh (same as the manual confirm path): a
            // full pass already in flight captured its source list
            // before this pin and would silently skip it.
            await repository.refreshSource(providerId: seeded.providerId)
        } catch {
            // Offline or misbehaving endpoint: the source stays
            // unpinned and the summary says so honestly. No retry
            // here — the walk must not block on the network.
        }
    }
}
