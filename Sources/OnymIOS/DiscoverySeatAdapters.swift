import Foundation
import os.log
import OnymChain
import OnymDiscovery
import OnymFoundation
import OnymModeration
import OnymTransportBlossom
import OnymTransportNostr

/// Discovery-backed implementations of the four seat "known list"
/// fetcher protocols. Lives in the app target — the one place all the
/// packages meet — so no seat package (OnymChain / OnymTransportNostr /
/// OnymTransportBlossom / OnymModeration) gains an OnymDiscovery
/// dependency.
///
/// Each adapter asks the verified discovery aggregate for entries of
/// its seat type, fetches every entry's destination manifest, verifies
/// it against the catalog-pinned digest and operator key
/// (`ServiceManifestReviewer` — hard-enforced), cross-checks the
/// manifest's componentId and seat against the catalog entry, and maps
/// the manifest to the seat's endpoint type. The result is MERGED with
/// the wrapped legacy GitHub-releases list — the legacy list is always
/// fetched, deduped by normalized endpoint URL, with the discovery
/// entry taking precedence for attribution — so discovery can only
/// ever *add* to what the app can do today, never take away: a single
/// surviving discovery entry must not evict the published defaults
/// from the known list (or from first-launch auto-populate, which
/// installs the whole fetched list). Per-entry review failures —
/// unreachable manifests, digest or signature mismatches, operator-key
/// / componentId / seat mismatches, unusable endpoint fields — drop
/// only that entry; when nothing survives the legacy list serves
/// alone, exactly as before discovery existed.
///
/// **Consent gate seam**: the known lists the three endpoint adapters
/// (relayers / Nostr / Blossom) produce don't just *list* endpoints —
/// they feed each repository's first-launch auto-populate
/// (`RelayerRepository.refresh` installs the whole fetched list when
/// no config exists; `NostrRelaysRepository` / `BlossomServersRepository`
/// `applyDefault` overwrite the config whenever the user never
/// customized those screens). A catalog entry reaching `fetchLatest`
/// therefore becomes a LIVE endpoint for default-config users, with
/// zero taps. So each endpoint adapter takes an optional
/// `hasActiveConsent` closure: when provided (the consent system is
/// wired in), only entries whose componentId the closure approves
/// merge into the known list; when nil (no consent system present in
/// this build layer), discovery entries are EXCLUDED from `fetchLatest`
/// entirely — pure legacy passthrough, no catalog review fan-out —
/// and catalog entries remain reachable only through the separate
/// catalog-entries surface (`DiscoveryRepository.entries(seatType:)`)
/// that consent-aware pickers read. The authorities adapter carries
/// the analogous `discoveryEnabled` seam: its list is a directory the
/// user picks from and moderation consent stays the signed mandate
/// downstream of the pick, but a listing's `apiBaseURL` and operator
/// key are what the mandate flow trusts, so catalog rows enter the
/// directory only in a build layer that ships the discovery surface
/// (nil → pure legacy passthrough). On a componentId collision the
/// LEGACY row always wins there — a catalog entry must never shadow a
/// published authority's endpoint or key.
///
/// `ContractsManifestFetcher` is deliberately NOT adapted: contracts
/// stay legacy-only in this effort (see the discovery design plan).

// MARK: - Seat vocabulary

/// The pinned mapping from a catalog entry's `seatType` to the `seat`
/// values a destination manifest may declare for it. The catalog and
/// the manifests are published by different pipelines, so the accepted
/// vocabulary is pinned HERE, from the real published manifests —
/// onym-relayer's `operator-manifest.src.json` declares
/// `seat: "notary"`, the onym-discovery deploy templates declare
/// `seat: "transport.message"` (courier) and `seat: "blob.storage"`
/// (blossom) — plus the historical aliases those seats have gone by
/// ("courier", "blossom"). A manifest whose `seat` is not in its
/// catalog entry's accepted set fails review and the entry is skipped:
/// a catalog must not be able to install, say, a blob server into the
/// notary seat by mislabeling the entry.
enum SeatManifestVocabulary {
    static let acceptedManifestSeats: [String: Set<String>] = [
        "notary": ["notary"],
        "transport.message": ["transport.message", "courier"],
        "blob.storage": ["blob.storage", "blossom"],
        // The LIVE authority manifest
        // (https://authority.onym.app/manifest.json) declares
        // `seat: "moderation"`; "authority" is tolerated as an alias
        // because `SignedServiceManifest`'s docs and onym-system's
        // moderation pages name the seat that way.
        "moderation": ["moderation", "authority"],
    ]

    /// Unknown catalog seat types (nothing in the table) accept only
    /// an exactly matching manifest seat — strict by default.
    static func accepts(catalogSeatType: String, manifestSeat: String) -> Bool {
        (acceptedManifestSeats[catalogSeatType] ?? [catalogSeatType]).contains(manifestSeat)
    }
}

// MARK: - Shared catalog seam

/// The two capabilities every adapter needs, as closures so app-target
/// tests can stub them without a repository or network:
/// entry lookup by seat type, and manifest-bytes fetch by URL.
struct DiscoverySeatCatalog: Sendable {
    let entries: @Sendable (_ seatType: String) async -> [AttributedCatalogEntry]
    let fetchManifestBytes: @Sendable (_ url: URL) async throws -> Data

    /// Upper bound on catalog entries reviewed per seat per fetch.
    /// Each surviving entry costs one manifest fetch; a hostile or
    /// bloated catalog must not be able to fan a known-list refresh
    /// out into hundreds of network requests. Entries beyond the cap
    /// are dropped with a log line (aggregate order, so which entries
    /// survive is deterministic).
    static let maxEntriesPerSeat = 16

    private static let log = Logger(subsystem: "app.onym.ios", category: "DiscoverySeatAdapters")

    /// Production wiring: entries from the repository's verified
    /// aggregate; manifest bytes through the discovery fetcher (seat
    /// manifests share the provider-manifest size cap — they are small
    /// signed JSON documents, not media).
    init(repository: DiscoveryRepository, fetcher: any DiscoveryFetching) {
        self.entries = { await repository.entries(seatType: $0) }
        self.fetchManifestBytes = { try await fetcher.fetchProviderManifest(url: $0) }
    }

    /// Test seam.
    init(
        entries: @escaping @Sendable (_ seatType: String) async -> [AttributedCatalogEntry],
        fetchManifestBytes: @escaping @Sendable (_ url: URL) async throws -> Data
    ) {
        self.entries = entries
        self.fetchManifestBytes = fetchManifestBytes
    }

    /// Fetch + review the destination manifest of every catalog entry
    /// for `seatType` (bounded by `maxEntriesPerSeat`), concurrently —
    /// the manifests live on unrelated hosts, so one slow operator
    /// must not serialize the rest. Output preserves the aggregate's
    /// entry order regardless of fetch completion order. Per-entry
    /// failures (unreachable, digest mismatch, bad signature, expired,
    /// operator-key / componentId / seat mismatch) skip that entry
    /// with a log line; the caller merges whatever survives with the
    /// legacy list.
    func reviewedEntries(seatType: String) async -> [ReviewedSeatEntry] {
        // §4.2 entry `status`: a provider-flagged `warning` entry is
        // excluded from known-list merges outright (before it costs a
        // manifest fetch or a cap slot) — the provider itself says the
        // entry is suspect, and no seat endpoint type has a field to
        // carry that flag on. `review`-flagged entries pass: the flag
        // stays available on `attributed.entry.status` for the
        // consent/picker surfaces (settings-UI layer) to render.
        let all = await entries(seatType).filter { attributed in
            guard attributed.entry.status?.state == "warning" else { return true }
            Self.log.error(
                "Discovery entry \(attributed.entry.componentId, privacy: .public): provider-flagged status \"warning\"; excluding from the known-list merge"
            )
            return false
        }
        if all.count > Self.maxEntriesPerSeat {
            Self.log.error(
                "Discovery seat \(seatType, privacy: .public): \(all.count) catalog entries exceed the per-seat cap (\(Self.maxEntriesPerSeat)); reviewing the first \(Self.maxEntriesPerSeat) only"
            )
        }
        let bounded = Array(all.prefix(Self.maxEntriesPerSeat))
        let fetchManifestBytes = self.fetchManifestBytes
        return await withTaskGroup(of: (Int, ReviewedSeatEntry?).self) { group in
            for (index, attributed) in bounded.enumerated() {
                group.addTask {
                    (index, await Self.reviewEntry(attributed, fetchManifestBytes: fetchManifestBytes))
                }
            }
            var slots = [ReviewedSeatEntry?](repeating: nil, count: bounded.count)
            for await (index, reviewed) in group {
                slots[index] = reviewed
            }
            return slots.compactMap { $0 }
        }
    }

    /// One entry's fetch + hard-enforced review: digest pin AND
    /// operator-key pin from the *verified* catalog entry (the
    /// verified side of this trust chain — a fetched manifest naming a
    /// different key is rejected, digest pin notwithstanding),
    /// embedded operator signature over the exact bytes, expiry, and
    /// the componentId + seat-vocabulary cross-checks binding the
    /// manifest to the entry that listed it.
    private static func reviewEntry(
        _ attributed: AttributedCatalogEntry,
        fetchManifestBytes: @Sendable (URL) async throws -> Data
    ) async -> ReviewedSeatEntry? {
        let entry = attributed.entry
        guard let manifestURL = entry.manifest.url else { return nil }
        do {
            let bytes = try await fetchManifestBytes(manifestURL)
            let reviewed = try ServiceManifestReviewer().review(
                raw: bytes,
                expectedDigest: entry.manifest.digest,
                expectedOperatorKey: entry.operatorKey
            )
            // The manifest must be the component the catalog listed…
            guard reviewed.signedManifest.componentId == entry.componentId else {
                log.error(
                    "Discovery entry \(entry.componentId, privacy: .public): manifest componentId \(reviewed.signedManifest.componentId, privacy: .public) differs from catalog entry; skipping"
                )
                return nil
            }
            // …declaring a seat the entry's seat type accepts.
            guard SeatManifestVocabulary.accepts(
                catalogSeatType: entry.seatType,
                manifestSeat: reviewed.signedManifest.seat
            ) else {
                log.error(
                    "Discovery entry \(entry.componentId, privacy: .public): manifest seat \(reviewed.signedManifest.seat, privacy: .public) not accepted for catalog seat type \(entry.seatType, privacy: .public); skipping"
                )
                return nil
            }
            return ReviewedSeatEntry(
                attributed: attributed,
                manifest: reviewed.signedManifest,
                fields: SeatManifestFields(rawBytes: reviewed.signedManifest.rawBytes)
            )
        } catch {
            log.error(
                "Discovery entry \(entry.componentId, privacy: .public): manifest review failed (\(String(describing: error), privacy: .public)); skipping"
            )
            return nil
        }
    }
}

/// One catalog entry whose destination manifest passed review, with
/// the seat-specific fields already projected out of the exact bytes.
struct ReviewedSeatEntry: Sendable {
    let attributed: AttributedCatalogEntry
    let manifest: SignedServiceManifest
    let fields: SeatManifestFields

    /// The endpoint role every published seat template declares for
    /// its client-facing endpoint (onym-courier / onym-blossom
    /// `deploy` templates; the notary template predates the field).
    static let preferredEndpointRole = "read-write"

    /// Display name: the manifest's `name` when the operator published
    /// one, else the component id minus its `onym:component:` prefix.
    var displayName: String {
        if let name = fields.name, !name.isEmpty { return name }
        let componentId = attributed.entry.componentId
        let prefix = "onym:component:"
        return componentId.hasPrefix(prefix)
            ? String(componentId.dropFirst(prefix.count))
            : componentId
    }

    /// The endpoint URL an adapter should use: among endpoints whose
    /// URI passes the profile URI rules (`DiscoveryFormat.isValidURI`
    /// — DNS host, no userinfo / query / fragment / port) under a
    /// scheme in `schemes`, prefer the first with the
    /// role every published template marks the client-facing endpoint
    /// with (`preferredEndpointRole`); when no endpoint carries that
    /// role — older manifests predate the field, and the vocabulary
    /// isn't closed — fall back to the first scheme-matching endpoint
    /// of any role, so a manifest that is usable stays usable.
    /// Scheme-only checks are not enough here: every other URL in
    /// OnymDiscovery goes through the §7 rules, and this one becomes
    /// a live connection target.
    func firstEndpointURL(schemes: Set<String>) -> URL? {
        func matches(_ endpoint: SeatManifestFields.Endpoint) -> URL? {
            // `schemes.contains` is the check that restricts the
            // scheme (lowercased — schemes are case-insensitive on
            // the wire); `isValidURI` then enforces the remaining §7
            // rules (DNS host, no userinfo / query / fragment / port)
            // for that scheme.
            guard let url = URL(string: endpoint.uri),
                  let scheme = url.scheme?.lowercased(),
                  schemes.contains(scheme),
                  DiscoveryFormat.isValidURI(endpoint.uri, scheme: scheme)
            else { return nil }
            return url
        }
        let candidates = fields.endpoints.compactMap { endpoint in
            matches(endpoint).map { (role: endpoint.role, url: $0) }
        }
        return candidates.first { $0.role == Self.preferredEndpointRole }?.url
            ?? candidates.first?.url
    }
}

/// Seat-specific fields projected out of a reviewed manifest's exact
/// bytes. `SignedServiceManifest` only parses the common spine
/// (componentId / seat / operator / offers / validUntil) and keeps
/// everything else inside `rawBytes` for seat adapters to interpret —
/// this is that interpretation. Deliberately tolerant: a manifest
/// whose seat-specific fields don't match the expected shape yields
/// empty projections here, the entry maps to nothing, and the legacy
/// list serves without it.
struct SeatManifestFields: Sendable {
    /// One `endpoints[]` element: the URI plus the published `role`
    /// (e.g. "read-write" in the deployed templates), when present.
    struct Endpoint: Sendable {
        let uri: String
        let role: String?
    }

    /// Top-level `name`, when published.
    let name: String?
    /// `endpoints[]`, in published order.
    let endpoints: [Endpoint]
    /// Top-level `networks` (notary seat: which Stellar networks the
    /// relayer serves), when published.
    let networks: [String]?

    /// `endpoints[].uri`, in published order. No caller in this layer —
    /// the settings-UI PR's consent-flow `apply` closures feed it to
    /// `ModuleConsentAcceptance.requiredEndpointURL` (same deal as
    /// `ModuleSelection` / `SeatSelectionStore`).
    var endpointURIs: [String] { endpoints.map(\.uri) }

    init(rawBytes: Data) {
        let object = ((try? JSONSerialization.jsonObject(with: rawBytes)) as? [String: Any]) ?? [:]
        name = object["name"] as? String
        if let endpoints = object["endpoints"] as? [[String: Any]] {
            self.endpoints = endpoints.compactMap { endpoint in
                (endpoint["uri"] as? String).map {
                    Endpoint(uri: $0, role: endpoint["role"] as? String)
                }
            }
        } else {
            endpoints = []
        }
        networks = object["networks"] as? [String]
    }
}

// MARK: - Merge

/// Union of the discovery-derived (consented) rows and the legacy
/// published list, deduped by `dedupeKey`. The legacy fetch starts
/// FIRST and runs concurrently with `discovered` (which performs the
/// manifest-review fan-out): one slow catalog operator must not delay
/// the published list — and with it first-launch auto-populate — by
/// up to a per-request timeout. The legacy list is ALWAYS fetched —
/// one surviving discovery entry must never evict the published
/// defaults (the known list feeds each repository's first-launch
/// auto-populate and the nostr/blossom `applyDefault` overwrite of
/// published defaults, so a replace here would make the whole
/// configuration discovery-only) — and on a duplicate key the
/// discovery entry wins the row (its reviewed attribution). Duplicate
/// keys *within* the discovery results (two providers listing the same
/// endpoint) also collapse to the first, keeping aggregate order. When
/// the legacy fetch fails, surviving discovery rows still serve
/// (discovery adds; a GitHub outage doesn't subtract them); with no
/// discovery rows the failure propagates exactly as the bare
/// legacy fetcher's would.
///
/// `legacyWinsOnCollision` flips who keeps a colliding key: the
/// endpoint adapters keep the discovery row (same URL, reviewed
/// attribution — nothing trust-carrying changes hands), but the
/// authorities adapter keys by componentId and its rows carry
/// `apiBaseURL` + the operator key, so there the LEGACY row must win —
/// discovery may only contribute componentIds the published directory
/// doesn't already list.
private func mergeDiscoveredWithLegacy<Endpoint: Sendable, Key: Hashable>(
    discovered: () async -> [Endpoint],
    dedupeKey: (Endpoint) -> Key,
    legacyWinsOnCollision: Bool = false,
    fetchLegacy: @escaping @Sendable () async throws -> [Endpoint]
) async throws -> [Endpoint] {
    async let legacyFetch = fetchLegacy()
    var seen = Set<Key>()
    let unique = await discovered().filter { seen.insert(dedupeKey($0)).inserted }
    let legacy: [Endpoint]
    do {
        legacy = try await legacyFetch
    } catch {
        guard !unique.isEmpty else { throw error }
        return unique
    }
    if legacyWinsOnCollision {
        let legacyKeys = Set(legacy.map(dedupeKey))
        return unique.filter { !legacyKeys.contains(dedupeKey($0)) } + legacy
    }
    return unique + legacy.filter { !seen.contains(dedupeKey($0)) }
}

/// Dedupe key for an endpoint URL: scheme and host lowercased (both
/// case-insensitive on the wire), one trailing slash stripped — so
/// `wss://Relay.Example/` and `wss://relay.example` collapse to one
/// row and one connection instead of two.
private func endpointDedupeKey(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    var key = components.string ?? url.absoluteString
    if key.hasSuffix("/") { key.removeLast() }
    return key
}

// MARK: - Notary seat (chain relayers)

/// `KnownRelayersFetcher` backed by discovery entries with seat type
/// "notary", merged with the legacy `relayers.json` list.
struct DiscoveryBackedKnownRelayersFetcher: KnownRelayersFetcher {
    static let seatType = "notary"
    /// A manifest without a `networks` field predates that field; the
    /// published relayers all serve both networks today, so this
    /// matches what `relayers.json` would say.
    static let defaultNetworks = ["testnet", "public"]

    let catalog: DiscoverySeatCatalog
    let fallback: any KnownRelayersFetcher
    /// Consent gate seam — see the file header. `true` iff the user
    /// holds an active consent record for the componentId; nil when no
    /// consent system is present, which excludes discovery entries
    /// from this known list entirely.
    let hasActiveConsent: (@Sendable (_ componentId: String) -> Bool)?

    /// Wrap `fallback` when a discovery catalog is available; identity
    /// when it isn't (UI-test harness).
    static func wrapping(
        _ fallback: any KnownRelayersFetcher,
        catalog: DiscoverySeatCatalog?,
        hasActiveConsent: (@Sendable (_ componentId: String) -> Bool)? = nil
    ) -> any KnownRelayersFetcher {
        guard let catalog else { return fallback }
        return DiscoveryBackedKnownRelayersFetcher(
            catalog: catalog,
            fallback: fallback,
            hasActiveConsent: hasActiveConsent
        )
    }

    func fetchLatest() async throws -> [RelayerEndpoint] {
        // No consent system in this build layer → pure legacy
        // passthrough, no catalog review fan-out (this list feeds
        // first-launch auto-populate; see the file header).
        guard let hasActiveConsent else { return try await fallback.fetchLatest() }
        return try await mergeDiscoveredWithLegacy(
            discovered: {
                await catalog.reviewedEntries(seatType: Self.seatType)
                    .filter { hasActiveConsent($0.attributed.entry.componentId) }
                    .compactMap { reviewed -> RelayerEndpoint? in
                        guard let url = reviewed.firstEndpointURL(schemes: ["https"])
                        else { return nil }
                        return RelayerEndpoint(
                            name: reviewed.displayName,
                            url: url,
                            networks: reviewed.fields.networks ?? Self.defaultNetworks
                        )
                    }
            },
            dedupeKey: { endpointDedupeKey($0.url) },
            fetchLegacy: fallback.fetchLatest
        )
    }
}

// MARK: - Message-transport seat (Nostr relays)

/// `KnownNostrRelaysFetcher` backed by discovery entries with seat
/// type "transport.message", merged with the legacy
/// `nostr-relays.json` list.
struct DiscoveryBackedKnownNostrRelaysFetcher: KnownNostrRelaysFetcher {
    static let seatType = "transport.message"

    let catalog: DiscoverySeatCatalog
    let fallback: any KnownNostrRelaysFetcher
    /// Consent gate seam — see the file header.
    let hasActiveConsent: (@Sendable (_ componentId: String) -> Bool)?

    static func wrapping(
        _ fallback: any KnownNostrRelaysFetcher,
        catalog: DiscoverySeatCatalog?,
        hasActiveConsent: (@Sendable (_ componentId: String) -> Bool)? = nil
    ) -> any KnownNostrRelaysFetcher {
        guard let catalog else { return fallback }
        return DiscoveryBackedKnownNostrRelaysFetcher(
            catalog: catalog,
            fallback: fallback,
            hasActiveConsent: hasActiveConsent
        )
    }

    func fetchLatest() async throws -> [NostrRelayEndpoint] {
        // No consent system in this build layer → pure legacy
        // passthrough (see the file header).
        guard let hasActiveConsent else { return try await fallback.fetchLatest() }
        return try await mergeDiscoveredWithLegacy(
            discovered: {
                await catalog.reviewedEntries(seatType: Self.seatType)
                    .filter { hasActiveConsent($0.attributed.entry.componentId) }
                    .compactMap { reviewed -> NostrRelayEndpoint? in
                        guard let url = reviewed.firstEndpointURL(schemes: ["wss"])
                        else { return nil }
                        // `isDefault` means "an Onym-published
                        // default" (the badge the settings rows
                        // render); a third-party catalog entry is
                        // not one, however it entered the list.
                        return NostrRelayEndpoint(
                            name: reviewed.displayName,
                            url: url,
                            isDefault: false
                        )
                    }
            },
            dedupeKey: { endpointDedupeKey($0.url) },
            fetchLegacy: fallback.fetchLatest
        )
    }
}

// MARK: - Blob-storage seat (Blossom servers)

/// `KnownBlossomServersFetcher` backed by discovery entries with seat
/// type "blob.storage", merged with the legacy `blossom-servers.json`
/// list.
struct DiscoveryBackedKnownBlossomServersFetcher: KnownBlossomServersFetcher {
    static let seatType = "blob.storage"

    let catalog: DiscoverySeatCatalog
    let fallback: any KnownBlossomServersFetcher
    /// Consent gate seam — see the file header.
    let hasActiveConsent: (@Sendable (_ componentId: String) -> Bool)?

    static func wrapping(
        _ fallback: any KnownBlossomServersFetcher,
        catalog: DiscoverySeatCatalog?,
        hasActiveConsent: (@Sendable (_ componentId: String) -> Bool)? = nil
    ) -> any KnownBlossomServersFetcher {
        guard let catalog else { return fallback }
        return DiscoveryBackedKnownBlossomServersFetcher(
            catalog: catalog,
            fallback: fallback,
            hasActiveConsent: hasActiveConsent
        )
    }

    func fetchLatest() async throws -> [BlossomServerEndpoint] {
        // No consent system in this build layer → pure legacy
        // passthrough (see the file header).
        guard let hasActiveConsent else { return try await fallback.fetchLatest() }
        return try await mergeDiscoveredWithLegacy(
            discovered: {
                await catalog.reviewedEntries(seatType: Self.seatType)
                    .filter { hasActiveConsent($0.attributed.entry.componentId) }
                    .compactMap { reviewed -> BlossomServerEndpoint? in
                        guard let url = reviewed.firstEndpointURL(schemes: ["https"])
                        else { return nil }
                        // Not an Onym-published default — see the
                        // Nostr adapter's note on `isDefault`.
                        return BlossomServerEndpoint(
                            name: reviewed.displayName,
                            url: url,
                            isDefault: false
                        )
                    }
            },
            dedupeKey: { endpointDedupeKey($0.url) },
            fetchLegacy: fallback.fetchLatest
        )
    }
}

// MARK: - Moderation seat (authorities)

/// `KnownAuthoritiesFetcher` backed by discovery entries with seat
/// type "moderation", MERGED with the legacy `authorities.json`
/// directory, keyed by componentId — same "add, never subtract" rule
/// as the endpoint adapters: a catalog with one moderation entry must
/// not hide every published authority. The authorities list is a
/// *directory the user picks from*, and consent for the moderation
/// seat stays the signed-mandate flow downstream of the pick — but
/// the directory rows themselves are trust-carrying: a listing's
/// `apiBaseURL` is where the user's signed mandate is sent, its
/// operator key is what the authority manifest is pinned against, and
/// `ModerationRepository` resolves the ACTIVE mandate's authority by
/// componentId. Two protections follow:
///
/// - **Legacy wins on collision**: a catalog entry reusing a published
///   authority's componentId must never replace that authority's
///   endpoint or key — discovery contributes only componentIds the
///   published directory doesn't list.
/// - **`discoveryEnabled` gate seam** (the authorities analogue of
///   the endpoint adapters' `hasActiveConsent`): nil — no discovery
///   surface in this build layer — is a pure legacy passthrough with
///   no catalog fan-out; the settings-UI layer that ships provider
///   management enables the merge.
struct DiscoveryBackedKnownAuthoritiesFetcher: KnownAuthoritiesFetcher {
    static let seatType = "moderation"

    let catalog: DiscoverySeatCatalog
    let fallback: any KnownAuthoritiesFetcher
    /// Gate seam — see the type doc. nil excludes discovery entries
    /// from the directory entirely.
    let discoveryEnabled: (@Sendable () -> Bool)?

    static func wrapping(
        _ fallback: any KnownAuthoritiesFetcher,
        catalog: DiscoverySeatCatalog?,
        discoveryEnabled: (@Sendable () -> Bool)? = nil
    ) -> any KnownAuthoritiesFetcher {
        guard let catalog else { return fallback }
        return DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: catalog,
            fallback: fallback,
            discoveryEnabled: discoveryEnabled
        )
    }

    func fetchLatest() async throws -> [AuthorityListing] {
        // No discovery surface in this build layer → pure legacy
        // passthrough, no catalog review fan-out (see the type doc).
        guard let discoveryEnabled, discoveryEnabled() else {
            return try await fallback.fetchLatest()
        }
        return try await mergeDiscoveredWithLegacy(
            discovered: { await discoveredListings() },
            dedupeKey: \.componentId,
            legacyWinsOnCollision: true,
            fetchLegacy: fallback.fetchLatest
        )
    }

    private func discoveredListings() async -> [AuthorityListing] {
        await catalog.reviewedEntries(seatType: Self.seatType)
            .compactMap { reviewed -> AuthorityListing? in
                let entry = reviewed.attributed.entry
                guard let manifestURL = entry.manifest.url,
                      let apiBaseURL = reviewed.firstEndpointURL(schemes: ["https"])
                else { return nil }
                // Same trust shape as the legacy directory: the
                // operator key is pinned out-of-band from the hosted
                // manifest — here it comes from the *verified catalog
                // entry* (signed by the pinned provider key), never
                // from the fetched manifest, so a MITM that swaps the
                // hosted manifest can't also swap the key it must
                // verify against.
                guard let keyBase64 = Self.operatorKeyBase64(fromOnymKey: entry.operatorKey) else {
                    return nil
                }
                return AuthorityListing(
                    componentId: entry.componentId,
                    name: reviewed.displayName,
                    manifestURL: manifestURL,
                    apiBaseURL: apiBaseURL,
                    operatorPublicKeyBase64: keyBase64
                )
            }
    }

    /// `onym:key:<64-lowercase-hex>` → base64 of the raw 32 key bytes
    /// (the encoding `AuthorityListing` / the mandate flow expect).
    /// Parsing and hex decoding go through the same verified helpers
    /// the discovery trust chain uses (`DiscoveryFormat.operatorKeyHex`
    /// + `Data(lowercaseHex:)`) — no second hand-rolled parser.
    static func operatorKeyBase64(fromOnymKey value: String) -> String? {
        guard let hex = DiscoveryFormat.operatorKeyHex(value),
              let bytes = Data(lowercaseHex: hex)
        else { return nil }
        return bytes.base64EncodedString()
    }
}
