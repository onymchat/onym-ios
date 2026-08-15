#if DEBUG
import Foundation
import OnymDiscovery

/// Discovery fakes for the `--ui-discovery` launch flag (honoured only
/// alongside `--ui-testing`). Sibling of `UITestFakes.swift` — same
/// rules: production sources because `OnymIOSApp.init` constructs them
/// directly, `#if DEBUG` so none of it ships to Release.
///
/// Unlike the other UI-test fakes these serve REAL signed documents:
/// the byte-pinned conformance fixtures from
/// `Packages/OnymDiscovery/Tests/OnymDiscoveryTests/Fixtures` (in turn
/// copied from onym-discovery's cross-language vectors). Their
/// signatures verify against the operator key embedded in the provider
/// manifest, so the app runs the full production `DiscoveryTrust`
/// pipeline — TOFU preview, key pinning, snapshot chain + expiry,
/// destination-manifest digest pin — entirely offline.
///
/// The fixtures are embedded as raw string literals rather than
/// bundled resources on purpose: every digest and signature is over
/// EXACT bytes, a `#"…"#` literal pins those bytes in source (the
/// files are single-line JSON with no backslashes), and the app target
/// gains no resource-plumbing through project.yml for test-only data.
/// If the package fixtures are ever regenerated, re-copy them here —
/// `UITestDiscoveryFixturesTests` in OnymIOSTests would be the place
/// to assert the copies stay byte-identical, but for now the embedded
/// digests below fail the trust checks loudly on any drift.
enum UITestDiscoveryFixtures {
    /// The seeded default source's manifest URL
    /// (`DiscoverySource.onymDefault.manifestURL`) — the flow under
    /// test TOFU-confirms the seeded default, so the fake must answer
    /// at exactly this URL.
    static let providerManifestURL = URL(string: "https://discovery.onym.app/manifest.json")!
    /// `catalogs[0].snapshot` inside the provider manifest.
    static let snapshotURL = URL(string: "https://discovery.onym.app/catalogs/public-all-seats.json")!
    /// `entries[0].manifest.uri` inside the snapshot (the destination
    /// manifest whose digest the entry pins), so the module-consent
    /// walk can fetch + review it offline.
    static let destinationManifestURL = URL(string: "https://discovery.onym.app/manifests/onym-courier.json")!

    /// The fixtures' signing-date neighborhood (2026-08-14T00:00:00Z;
    /// same instant as `Fixture.now` in OnymDiscoveryTests): validity
    /// spans 2026-08-13 → snapshot expiry 2026-09-12. Injected as the
    /// repository's `now` so the UI tests keep passing after the real
    /// clock passes the fixtures' expiry.
    static let now = Date(timeIntervalSince1970: 1_786_665_600)

    /// First 16 hex chars of the fixtures' operator key
    /// (`ea4a6c63e29c520a…`), grouped as the TOFU screen renders it.
    /// UI tests assert against this exact string.
    static let operatorKeyFingerprint = "ea4a 6c63 e29c 520a"

    /// `provider-manifest.json`, byte-exact.
    static let providerManifest = Data(#"{"capabilities":["signed-snapshot-v1","local-filtering-v1"],"catalogs":[{"audience":"public","catalogId":"public-all-seats","policy":"sha256:1111111111111111111111111111111111111111111111111111111111111111","policyUri":"https://discovery.onym.app/policies/public-all-seats.md","seatTypes":["transport.message","notary","moderation"],"snapshot":"https://discovery.onym.app/catalogs/public-all-seats.json"}],"implementationProfileId":"onym:discovery-implementation:static-ed25519-v1","offers":[],"operator":"onym:key:ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c","privacyProfile":"sha256:3333333333333333333333333333333333333333333333333333333333333333","privacyProfileUri":"https://discovery.onym.app/privacy.md","providerId":"onym:component:onym-discovery","seat":"discovery","signature":"G3c5sbqgFpN7X+sq95d2Mkeg8yfy/gjz7w9b5HaPjpFwCKtbmZ8lqy2sJhYIYGlZQ0q9S3XmrpBcRfFLpmsDCQ==","validUntil":"2026-12-31T23:59:59Z","version":1}"#.utf8)

    /// `snapshot-1.json`, byte-exact (sequence 1, no `previousDigest`
    /// — the clean start of the chain; the in-memory store begins with
    /// no retained snapshots, so re-serving the same bytes on every
    /// refresh is a valid no-change chain step).
    static let snapshot = Data(#"{"catalogId":"public-all-seats","entries":[{"componentId":"onym:component:onym-courier","evidence":[],"listedAt":"2026-08-13T00:00:00Z","manifest":{"digest":"sha256:6536b1a70c859fae21afc610035a924a1a96a842c8b124094ed4978d828f1c45","uri":"https://discovery.onym.app/manifests/onym-courier.json"},"operator":"onym:key:ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c","placement":"policy-ranked","profiles":["onym:message-implementation:nostr-courier-v1"],"relationship":"common-owner","seatType":"transport.message"}],"expiresAt":"2026-09-12T00:00:00Z","generatedAt":"2026-08-13T00:00:00Z","implementationProfileId":"onym:discovery-implementation:static-ed25519-v1","policyDigest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","providerId":"onym:component:onym-discovery","sequence":1,"signature":"tcU3eQryNBpH16Hea/v4h4AixpZNazAv5DzYmYxx3GOAnbL3ePZwboON8s9aJApIdN+JvUC15wzdWR0l3zLCAw==","version":1}"#.utf8)

    /// `destination-manifest.json`, byte-exact — its sha256 must equal
    /// the `manifest.digest` the snapshot entry pins.
    static let destinationManifest = Data(#"{"componentId":"onym:component:onym-courier","endpoints":[{"role":"read-write","uri":"wss://nostr.onym.app"}],"offers":[{"model":"free","offerId":"courier-free-v1"}],"operator":"onym:key:ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c","seat":"transport.message","signature":"mDLXl2yEQa8OJvLqgUP8kRNakcIQybq2gKia2UCrGguuWNLPCH4MJ2Pvw1jNlUiM90dtSWHkmjZpxMpb3nAgAQ==","validUntil":"2026-12-31T23:59:59Z","version":1}"#.utf8)
}

/// `DiscoveryFetching` that serves the fixture bytes by exact URL and
/// answers 404 for anything else — dumb by design (the seam contract:
/// bytes out, all parsing/verification stays in the trust layer).
/// Destination manifests go through `fetchProviderManifest` because
/// that is the method `DiscoverySeatCatalog` fetches them with (they
/// share the provider-manifest size cap).
struct UITestDiscoveryFetcher: DiscoveryFetching {
    func fetchProviderManifest(url: URL) async throws -> Data {
        switch url {
        case UITestDiscoveryFixtures.providerManifestURL:
            return UITestDiscoveryFixtures.providerManifest
        case UITestDiscoveryFixtures.destinationManifestURL:
            return UITestDiscoveryFixtures.destinationManifest
        default:
            throw DiscoveryFetchError.badStatus(404)
        }
    }

    func fetchSnapshot(url: URL) async throws -> Data {
        guard url == UITestDiscoveryFixtures.snapshotURL else {
            throw DiscoveryFetchError.badStatus(404)
        }
        return UITestDiscoveryFixtures.snapshot
    }
}

/// In-memory `DiscoveryStore` so each UI-test launch starts with no
/// persisted configuration (the repository then seeds the unconfirmed
/// default source) and no retained snapshots — same launch-isolation
/// pattern as the other `UITest*Store`s.
final class InMemoryDiscoveryStore: DiscoveryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: DiscoverySourcesConfiguration = .empty
    private var snapshots: [String: Data] = [:]

    private static func key(_ providerId: String, _ catalogId: String) -> String {
        // providerId/catalogId charsets exclude "|" (enforced by the
        // trust layer's format checks), so the join is unambiguous.
        providerId + "|" + catalogId
    }

    func loadConfiguration() -> DiscoverySourcesConfiguration {
        lock.withLock { configuration }
    }

    func saveConfiguration(_ configuration: DiscoverySourcesConfiguration) {
        lock.withLock { self.configuration = configuration }
    }

    func loadRetainedSnapshot(providerId: String, catalogId: String) -> Data? {
        lock.withLock { snapshots[Self.key(providerId, catalogId)] }
    }

    func saveRetainedSnapshot(_ raw: Data, providerId: String, catalogId: String) {
        lock.withLock { snapshots[Self.key(providerId, catalogId)] = raw }
    }

    func removeRetainedSnapshots(providerId: String) {
        lock.withLock {
            let prefix = providerId + "|"
            for key in snapshots.keys where key.hasPrefix(prefix) {
                snapshots.removeValue(forKey: key)
            }
        }
    }
}

#endif
