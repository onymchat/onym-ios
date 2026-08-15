import CryptoKit
import Foundation
import XCTest
@testable import OnymIOS
import OnymChain
import OnymDiscovery
import OnymFoundation
import OnymModeration
import OnymTransportBlossom
import OnymTransportNostr

/// Fallback-ordering + mapping tests for the discovery-backed seat
/// fetchers in `DiscoverySeatAdapters.swift`. The catalog seam is
/// stubbed with closures — no repository, no network; destination
/// manifests are freshly Ed25519-signed the way an operator's
/// publishing pipeline would sign them, because the reviewer is
/// hard-enforced (no accept-anyway path to sneak fixtures through).
final class DiscoverySeatAdaptersTests: XCTestCase {
    // MARK: - Manifest factory

    /// Serialize, sign the canonical form, embed the signature. Same
    /// recipe as `ManifestFactory` in OnymFoundationTests.
    private static func signedManifestBytes(
        object: [String: Any],
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        var object = object
        object.removeValue(forKey: "signature")
        let unsigned = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let signingBytes = try ServiceManifestCanonical.signingBytes(of: unsigned)
        let signature = try key.signature(for: signingBytes)
        object["signature"] = signature.base64EncodedString()
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(of data: Data) -> String {
        "sha256:" + hex(Data(SHA256.hash(data: data)))
    }

    /// A signed destination manifest plus the matching verified-catalog
    /// entry wrapped in attribution — everything an adapter consumes.
    private struct Seeded {
        let entry: AttributedCatalogEntry
        let manifestBytes: Data
        let operatorKeyHex: String
    }

    private static func seeded(
        componentId: String = "onym:component:test-component",
        seatType: String,
        manifestExtras: [String: Any],
        manifestURI: String = "https://provider.example/manifests/component.json",
        providerId: String = "onym:component:test-provider",
        manifestComponentIdOverride: String? = nil,
        manifestSeatOverride: String? = nil,
        entryOperatorOverrideHex: String? = nil,
        entryDigestOverride: String? = nil,
        entryStatus: [String: Any]? = nil
    ) throws -> Seeded {
        let key = Curve25519.Signing.PrivateKey()
        let keyHex = hex(key.publicKey.rawRepresentation)
        var object: [String: Any] = [
            "componentId": manifestComponentIdOverride ?? componentId,
            "seat": manifestSeatOverride ?? seatType,
            "operator": "onym:key:\(keyHex)",
            "validUntil": "2030-01-01T00:00:00Z",
        ]
        object.merge(manifestExtras) { _, new in new }
        let bytes = try signedManifestBytes(object: object, key: key)

        var entryJSON: [String: Any] = [
            "componentId": componentId,
            "seatType": seatType,
            "manifest": [
                "uri": manifestURI,
                "digest": entryDigestOverride ?? digest(of: bytes),
            ],
            "operator": "onym:key:\(entryOperatorOverrideHex ?? keyHex)",
            "profiles": [],
            "evidence": [],
            "listedAt": "2026-01-01T00:00:00Z",
            "relationship": "none",
            "placement": "neutral",
        ]
        if let entryStatus { entryJSON["status"] = entryStatus }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(
            CatalogEntry.self,
            from: JSONSerialization.data(withJSONObject: entryJSON)
        )
        let attributed = AttributedCatalogEntry(
            entry: entry,
            source: SourceAttribution(
                providerId: providerId,
                sourceLabel: "Test Provider",
                catalogId: "public",
                snapshotDigest: "sha256:" + String(repeating: "0", count: 64),
                relationship: "none",
                placement: "neutral"
            )
        )
        return Seeded(entry: attributed, manifestBytes: bytes, operatorKeyHex: keyHex)
    }

    private static func catalog(_ seeded: [Seeded]) -> DiscoverySeatCatalog {
        DiscoverySeatCatalog(
            entries: { seatType in
                seeded.map(\.entry).filter { $0.entry.seatType == seatType }
            },
            fetchManifestBytes: { url in
                guard let match = seeded.first(where: { $0.entry.entry.manifest.url == url }) else {
                    throw URLError(.fileDoesNotExist)
                }
                return match.manifestBytes
            }
        )
    }

    private static let emptyCatalog = DiscoverySeatCatalog(
        entries: { _ in [] },
        fetchManifestBytes: { _ in throw URLError(.fileDoesNotExist) }
    )

    // MARK: - Fallback stubs

    private struct StubRelayersFallback: KnownRelayersFetcher {
        static let sentinel = [RelayerEndpoint(
            name: "Legacy Relayer",
            url: URL(string: "https://legacy.example")!,
            networks: ["testnet"]
        )]
        func fetchLatest() async throws -> [RelayerEndpoint] { Self.sentinel }
    }

    private struct StubNostrFallback: KnownNostrRelaysFetcher {
        static let sentinel = [NostrRelayEndpoint(
            name: "Legacy Nostr",
            url: URL(string: "wss://legacy.example")!,
            isDefault: true
        )]
        func fetchLatest() async throws -> [NostrRelayEndpoint] { Self.sentinel }
    }

    private struct StubBlossomFallback: KnownBlossomServersFetcher {
        static let sentinel = [BlossomServerEndpoint(
            name: "Legacy Blossom",
            url: URL(string: "https://legacy-blossom.example")!,
            isDefault: true
        )]
        func fetchLatest() async throws -> [BlossomServerEndpoint] { Self.sentinel }
    }

    private struct StubAuthoritiesFallback: KnownAuthoritiesFetcher {
        static let sentinel = [AuthorityListing(
            componentId: "onym:component:legacy-authority",
            name: "Legacy Authority",
            manifestURL: URL(string: "https://legacy.example/manifest.json")!,
            apiBaseURL: URL(string: "https://legacy.example/api")!,
            operatorPublicKeyBase64: Data(repeating: 7, count: 32).base64EncodedString()
        )]
        func fetchLatest() async throws -> [AuthorityListing] { Self.sentinel }
    }

    // MARK: - Relayers (notary seat)

    func test_relayers_emptyCatalogFallsBackToLegacy() async throws {
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.emptyCatalog,
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    func test_relayers_mapsVerifiedManifestToEndpoint() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Test Notary",
                "endpoints": [["role": "submit", "uri": "https://notary.example/api"]],
                "networks": ["testnet"],
            ]
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, [RelayerEndpoint(
            name: "Test Notary",
            url: URL(string: "https://notary.example/api")!,
            networks: ["testnet"]
        )] + StubRelayersFallback.sentinel,
        "the discovery entry is MERGED with the legacy list, never a replacement for it")
    }

    /// The replace-vs-add regression: the known list feeds
    /// `RelayerRepository`'s first-launch auto-populate (and the
    /// nostr/blossom repositories' `applyDefault`), so one surviving
    /// discovery entry must not make the fetched list discovery-only —
    /// the published defaults must survive in the union, discovery
    /// entries first (aggregate order), legacy after.
    func test_relayers_multipleEntriesUnionWithLegacyList() async throws {
        let first = try Self.seeded(
            componentId: "onym:component:notary-one",
            seatType: "notary",
            manifestExtras: [
                "name": "Notary One",
                "endpoints": [["uri": "https://one.example/api"]],
            ],
            manifestURI: "https://provider.example/manifests/one.json"
        )
        let second = try Self.seeded(
            componentId: "onym:component:notary-two",
            seatType: "notary",
            manifestExtras: [
                "name": "Notary Two",
                "endpoints": [["uri": "https://two.example/api"]],
            ],
            manifestURI: "https://provider.example/manifests/two.json"
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([first, second]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Notary One", "Notary Two", "Legacy Relayer"])
        XCTAssertEqual(result.map(\.url), [
            URL(string: "https://one.example/api")!,
            URL(string: "https://two.example/api")!,
            URL(string: "https://legacy.example")!,
        ])
    }

    /// Partial failure: one entry's review fails (digest mismatch),
    /// the other entries — and the legacy list — survive. A bad entry
    /// costs itself, never the seat.
    func test_relayers_partialReviewFailureKeepsSurvivorsAndLegacy() async throws {
        let bad = try Self.seeded(
            componentId: "onym:component:bad-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Bad Notary",
                "endpoints": [["uri": "https://bad.example/api"]],
            ],
            manifestURI: "https://provider.example/manifests/bad.json",
            entryDigestOverride: "sha256:" + String(repeating: "e", count: 64)
        )
        let good = try Self.seeded(
            componentId: "onym:component:good-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Good Notary",
                "endpoints": [["uri": "https://good.example/api"]],
            ],
            manifestURI: "https://provider.example/manifests/good.json"
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([bad, good]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Good Notary", "Legacy Relayer"])
    }

    /// Dedupe by URL across the merge: when a discovery entry serves
    /// the same endpoint URL a published entry lists, the discovery
    /// entry wins the row (its reviewed attribution), and the URL
    /// appears exactly once. Two providers listing the same URL
    /// (cross-provider duplicate) also collapse to one row — the
    /// first in aggregate order.
    func test_relayers_mergeDedupesByURLWithDiscoveryAttributionWinning() async throws {
        let overlapsLegacy = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Catalog Name For Legacy URL",
                "endpoints": [["uri": "https://legacy.example"]],
            ],
            manifestURI: "https://provider.example/manifests/overlap.json",
            providerId: "onym:component:provider-a"
        )
        let crossProviderDuplicate = try Self.seeded(
            componentId: "onym:component:other-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Same URL, Other Provider",
                "endpoints": [["uri": "https://legacy.example"]],
            ],
            manifestURI: "https://other-provider.example/manifests/overlap.json",
            providerId: "onym:component:provider-b"
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([overlapsLegacy, crossProviderDuplicate]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.url), [URL(string: "https://legacy.example")!])
        XCTAssertEqual(result.map(\.name), ["Catalog Name For Legacy URL"])
    }

    /// A legacy-list outage must not subtract surviving discovery
    /// endpoints; with no discovery endpoints the failure propagates
    /// exactly as the bare legacy fetcher's would.
    func test_relayers_legacyFetchFailureStillServesDiscoveredEndpoints() async throws {
        struct FailingFallback: KnownRelayersFetcher {
            func fetchLatest() async throws -> [RelayerEndpoint] {
                throw URLError(.notConnectedToInternet)
            }
        }
        let seeded = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Discovered Notary",
                "endpoints": [["uri": "https://discovered.example/api"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: FailingFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Discovered Notary"])

        let emptyDiscovery = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.emptyCatalog,
            fallback: FailingFallback(),
            hasActiveConsent: { _ in true }
        )
        do {
            _ = try await emptyDiscovery.fetchLatest()
            XCTFail("with nothing discovered, the legacy failure must propagate")
        } catch {}
    }

    /// The seat-vocabulary pin: a manifest declaring a seat outside
    /// its catalog entry's accepted set is skipped — a catalog can't
    /// install a blob server into the notary seat by mislabeling the
    /// entry.
    func test_relayers_manifestSeatOutsideVocabularyIsSkipped() async throws {
        let mislabeled = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: ["endpoints": [["uri": "https://notary.example/api"]]],
            manifestSeatOverride: "blob.storage"
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([mislabeled]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    /// The componentId cross-check: the fetched manifest must be the
    /// component the catalog listed.
    func test_relayers_manifestComponentIdMismatchIsSkipped() async throws {
        let swapped = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: ["endpoints": [["uri": "https://notary.example/api"]]],
            manifestComponentIdOverride: "onym:component:some-other-notary"
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([swapped]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    /// Role preference: among scheme-matching endpoints, the first
    /// with role "read-write" (what every published template marks the
    /// client-facing endpoint with) wins over earlier endpoints with
    /// other roles; with no "read-write" endpoint the first
    /// scheme-matching endpoint serves (documented fallback).
    func test_relayers_prefersReadWriteRoleEndpoint() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Test Notary",
                "endpoints": [
                    ["role": "metrics", "uri": "https://metrics.example/api"],
                    ["role": "read-write", "uri": "https://serve.example/api"],
                ],
            ]
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.first?.url, URL(string: "https://serve.example/api"))

        let noPreferredRole = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: [
                "endpoints": [
                    ["role": "submit", "uri": "https://first.example/api"],
                    ["role": "api", "uri": "https://second.example/api"],
                ],
            ]
        )
        let fallbackFetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([noPreferredRole]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let fallbackResult = try await fallbackFetcher.fetchLatest()
        XCTAssertEqual(fallbackResult.first?.url, URL(string: "https://first.example/api"))
    }

    /// The per-seat entry cap: entries beyond `maxEntriesPerSeat` are
    /// dropped (deterministically — aggregate order) instead of
    /// fanning a refresh out into unbounded manifest fetches.
    func test_relayers_entriesBeyondPerSeatCapAreDropped() async throws {
        let count = DiscoverySeatCatalog.maxEntriesPerSeat + 2
        let seeded = try (0..<count).map { index in
            try Self.seeded(
                componentId: "onym:component:notary-\(index)",
                seatType: "notary",
                manifestExtras: [
                    "name": "Notary \(index)",
                    "endpoints": [["uri": "https://notary-\(index).example/api"]],
                ],
                manifestURI: "https://provider.example/manifests/notary-\(index).json"
            )
        }
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog(seeded),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        // First `maxEntriesPerSeat` discovery entries in aggregate
        // order, then the legacy list.
        XCTAssertEqual(
            result.map(\.name),
            (0..<DiscoverySeatCatalog.maxEntriesPerSeat).map { "Notary \($0)" } + ["Legacy Relayer"]
        )
    }

    func test_relayers_defaultsNetworksAndNameWhenManifestOmitsThem() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-notary",
            seatType: "notary",
            manifestExtras: [
                "endpoints": [["uri": "https://notary.example/api"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.first?.name, "test-notary")
        XCTAssertEqual(result.first?.networks, ["testnet", "public"])
    }

    func test_relayers_digestMismatchFallsBackToLegacy() async throws {
        let seeded = try Self.seeded(
            seatType: "notary",
            manifestExtras: [
                "endpoints": [["uri": "https://notary.example/api"]],
            ],
            entryDigestOverride: "sha256:" + String(repeating: "e", count: 64)
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    func test_relayers_manifestFetchFailureFallsBackToLegacy() async throws {
        let seeded = try Self.seeded(
            seatType: "notary",
            manifestExtras: ["endpoints": [["uri": "https://notary.example/api"]]]
        )
        let unreachable = DiscoverySeatCatalog(
            entries: { _ in [seeded.entry] },
            fetchManifestBytes: { _ in throw URLError(.notConnectedToInternet) }
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: unreachable,
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    // MARK: - Nostr relays (transport.message seat)

    func test_nostr_mapsWssEndpointAndSkipsNonWss() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-courier",
            seatType: "transport.message",
            manifestExtras: [
                "name": "Test Courier",
                "endpoints": [
                    ["role": "http-fallback", "uri": "https://courier.example"],
                    ["role": "read-write", "uri": "wss://nostr.courier.example"],
                ],
            ]
        )
        let fetcher = DiscoveryBackedKnownNostrRelaysFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubNostrFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, [NostrRelayEndpoint(
            name: "Test Courier",
            url: URL(string: "wss://nostr.courier.example")!,
            // Third-party catalog entries must not wear the
            // Onym-published "Default" badge.
            isDefault: false
        )] + StubNostrFallback.sentinel,
        "the shipped default relays must survive a discovery transport entry")
    }

    func test_nostr_manifestWithoutWssEndpointFallsBackToLegacy() async throws {
        let seeded = try Self.seeded(
            seatType: "transport.message",
            manifestExtras: ["endpoints": [["uri": "https://courier.example"]]]
        )
        let fetcher = DiscoveryBackedKnownNostrRelaysFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubNostrFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubNostrFallback.sentinel)
    }

    // MARK: - Blossom servers (blob.storage seat)

    func test_blossom_mapsHTTPSEndpoint() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-blossom",
            seatType: "blob.storage",
            manifestExtras: [
                "name": "Test Blossom",
                "endpoints": [["uri": "https://blobs.example"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownBlossomServersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubBlossomFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, [BlossomServerEndpoint(
            name: "Test Blossom",
            url: URL(string: "https://blobs.example")!,
            // Third-party catalog entries must not wear the
            // Onym-published "Default" badge.
            isDefault: false
        )] + StubBlossomFallback.sentinel,
        "the published default servers must survive a discovery blob entry")
    }

    func test_blossom_emptyCatalogFallsBackToLegacy() async throws {
        let fetcher = DiscoveryBackedKnownBlossomServersFetcher(
            catalog: Self.emptyCatalog,
            fallback: StubBlossomFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubBlossomFallback.sentinel)
    }

    // MARK: - Authorities (moderation seat)

    func test_authorities_mapsCatalogEntryWithConvertedOperatorKey() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-authority",
            seatType: "moderation",
            manifestExtras: [
                "name": "Test Authority",
                "endpoints": [["role": "api", "uri": "https://authority.example/api"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubAuthoritiesFallback(),
            discoveryEnabled: { true }
        )
        let result = try await fetcher.fetchLatest()
        // Merged by componentId with the legacy directory — the
        // catalog entry first (aggregate order), the published
        // authorities after it, never subtracted.
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last, StubAuthoritiesFallback.sentinel[0])
        let listing = try XCTUnwrap(result.first)
        XCTAssertEqual(listing.componentId, "onym:component:test-authority")
        XCTAssertEqual(listing.name, "Test Authority")
        XCTAssertEqual(
            listing.manifestURL,
            URL(string: "https://provider.example/manifests/component.json")
        )
        XCTAssertEqual(listing.apiBaseURL, URL(string: "https://authority.example/api"))
        // The key must be the CATALOG entry's operator key (base64 of
        // the raw 32 bytes), not anything read out of the manifest.
        let expectedKeyData = Data(
            stride(from: 0, to: seeded.operatorKeyHex.count, by: 2).map { offset -> UInt8 in
                let start = seeded.operatorKeyHex.index(
                    seeded.operatorKeyHex.startIndex, offsetBy: offset
                )
                let end = seeded.operatorKeyHex.index(start, offsetBy: 2)
                return UInt8(seeded.operatorKeyHex[start..<end], radix: 16)!
            }
        )
        XCTAssertEqual(listing.operatorPublicKeyBase64, expectedKeyData.base64EncodedString())
    }

    func test_authorities_operatorKeyMismatchWithManifestFallsBackToLegacy() async throws {
        // Catalog names a different operator than the manifest is
        // signed by — the adapter must reject the entry (the catalog
        // is the verified side) and fall back.
        let otherKeyHex = Self.hex(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        let seeded = try Self.seeded(
            seatType: "moderation",
            manifestExtras: ["endpoints": [["uri": "https://authority.example/api"]]],
            entryOperatorOverrideHex: otherKeyHex
        )
        let fetcher = DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubAuthoritiesFallback(),
            discoveryEnabled: { true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubAuthoritiesFallback.sentinel)
    }

    func test_operatorKeyBase64Conversion() {
        let hex = (0..<32).map { String(format: "%02x", $0) }.joined()
        let expected = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        XCTAssertEqual(
            DiscoveryBackedKnownAuthoritiesFetcher.operatorKeyBase64(
                fromOnymKey: "onym:key:\(hex)"
            ),
            expected
        )
        XCTAssertNil(
            DiscoveryBackedKnownAuthoritiesFetcher.operatorKeyBase64(fromOnymKey: "onym:key:short")
        )
        XCTAssertNil(
            DiscoveryBackedKnownAuthoritiesFetcher.operatorKeyBase64(fromOnymKey: hex)
        )
    }

    // MARK: - Consent gate seam

    /// With NO consent system present (`hasActiveConsent: nil` — this
    /// PR standalone), discovery entries are excluded from the known
    /// list entirely: the adapter is a pure legacy passthrough and
    /// never even fans out into the catalog. The known list feeds
    /// first-launch auto-populate and the nostr/blossom
    /// `applyDefault`, so anything that reaches it becomes a LIVE
    /// endpoint for default-config users — nothing may reach it
    /// without a consent record.
    func test_relayers_nilConsentClosureServesLegacyOnlyWithoutCatalogFanout() async throws {
        let catalog = DiscoverySeatCatalog(
            entries: { _ in
                XCTFail("no consent system present: the catalog must not be consulted")
                return []
            },
            fetchManifestBytes: { _ in
                XCTFail("no consent system present: no manifest may be fetched")
                throw URLError(.fileDoesNotExist)
            }
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: catalog,
            fallback: StubRelayersFallback(),
            hasActiveConsent: nil
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    func test_nostr_nilConsentClosureServesLegacyOnly() async throws {
        let seeded = try Self.seeded(
            seatType: "transport.message",
            manifestExtras: ["endpoints": [["uri": "wss://nostr.courier.example"]]]
        )
        let fetcher = DiscoveryBackedKnownNostrRelaysFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubNostrFallback(),
            hasActiveConsent: nil
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubNostrFallback.sentinel)
    }

    func test_blossom_nilConsentClosureServesLegacyOnly() async throws {
        let seeded = try Self.seeded(
            seatType: "blob.storage",
            manifestExtras: ["endpoints": [["uri": "https://blobs.example"]]]
        )
        let fetcher = DiscoveryBackedKnownBlossomServersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubBlossomFallback(),
            hasActiveConsent: nil
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubBlossomFallback.sentinel)
    }

    /// With the consent system wired in, only entries the closure
    /// approves merge into the known list — unconsented entries stay
    /// picker-only.
    func test_relayers_consentGateAdmitsOnlyConsentedEntries() async throws {
        let consented = try Self.seeded(
            componentId: "onym:component:notary-one",
            seatType: "notary",
            manifestExtras: [
                "name": "Notary One",
                "endpoints": [["uri": "https://one.example/api"]],
            ],
            manifestURI: "https://provider.example/manifests/one.json"
        )
        let unconsented = try Self.seeded(
            componentId: "onym:component:notary-two",
            seatType: "notary",
            manifestExtras: [
                "name": "Notary Two",
                "endpoints": [["uri": "https://two.example/api"]],
            ],
            manifestURI: "https://provider.example/manifests/two.json"
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([consented, unconsented]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { $0 == "onym:component:notary-one" }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Notary One", "Legacy Relayer"])
    }

    // MARK: - Endpoint URI rules + dedupe normalization

    /// Manifest endpoint URIs go through the same §7 URI rules as
    /// every other URL in OnymDiscovery — userinfo, query, fragment,
    /// and explicit ports are rejected, not just wrong schemes.
    func test_relayers_endpointURIOutsideProfileRulesIsSkipped() async throws {
        let seeded = try Self.seeded(
            seatType: "notary",
            manifestExtras: [
                "endpoints": [
                    ["uri": "https://user:pass@notary.example:8443/x?q=1"],
                    ["uri": "https://notary.example:8443/api"],
                    ["uri": "https://notary.example/api?q=1"],
                ],
            ]
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    /// Dedupe keys are normalized — scheme+host lowercased, trailing
    /// slash stripped — so `wss://LEGACY.example/` and
    /// `wss://legacy.example` collapse to one row (and one relay
    /// connection), with the discovery attribution winning the row.
    func test_nostr_mergeDedupeNormalizesCaseAndTrailingSlash() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-courier",
            seatType: "transport.message",
            manifestExtras: [
                "name": "Case Variant Courier",
                "endpoints": [["uri": "wss://LEGACY.example/"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownNostrRelaysFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubNostrFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Case Variant Courier"])
    }

    // MARK: - Entry status

    /// A provider-flagged `warning` entry is excluded from known-list
    /// merges outright — the provider itself marked it suspect, and no
    /// seat endpoint type has a field to carry the flag on.
    func test_relayers_warningStatusEntryIsExcluded() async throws {
        let flagged = try Self.seeded(
            componentId: "onym:component:flagged-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Flagged Notary",
                "endpoints": [["uri": "https://flagged.example/api"]],
            ],
            entryStatus: ["state": "warning", "uri": "https://provider.example/warning"]
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([flagged]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }

    /// A `review`-flagged entry passes the merge — the flag stays on
    /// `attributed.entry.status` for the consent/picker surfaces to
    /// render; no endpoint type has a field to carry it further.
    func test_relayers_reviewStatusEntryStillMerges() async throws {
        let underReview = try Self.seeded(
            componentId: "onym:component:review-notary",
            seatType: "notary",
            manifestExtras: [
                "name": "Review Notary",
                "endpoints": [["uri": "https://review.example/api"]],
            ],
            entryStatus: ["state": "review"]
        )
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: Self.catalog([underReview]),
            fallback: StubRelayersFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Review Notary", "Legacy Relayer"])
    }

    /// Schemes are case-insensitive on the wire: a manifest publishing
    /// `WSS://…` maps like `wss://…`, instead of being silently
    /// dropped by an exact-case scheme comparison.
    func test_nostr_uppercaseSchemeEndpointStillMaps() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-courier",
            seatType: "transport.message",
            manifestExtras: [
                "name": "Shouting Courier",
                "endpoints": [["uri": "WSS://nostr.courier.example"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownNostrRelaysFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubNostrFallback(),
            hasActiveConsent: { _ in true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Shouting Courier", "Legacy Nostr"])
    }

    // MARK: - Authorities merge semantics

    /// The directory merge is LEGACY-wins on a componentId collision:
    /// an authority listing's `apiBaseURL` + operator key are what the
    /// mandate flow trusts, and `ModerationRepository` resolves the
    /// active mandate's authority by componentId — so a catalog entry
    /// reusing a published authority's componentId must never shadow
    /// the published row (which would redirect mandate traffic and
    /// put an attacker-controlled key behind re-consent). Discovery
    /// may only contribute componentIds the directory doesn't list.
    func test_authorities_duplicateComponentIdKeepsLegacyRow() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:legacy-authority",
            seatType: "moderation",
            manifestExtras: [
                "name": "Catalog Authority",
                "endpoints": [["uri": "https://attacker.example/api"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubAuthoritiesFallback(),
            discoveryEnabled: { true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubAuthoritiesFallback.sentinel,
            "the published authority's row — apiBaseURL and operator key included — must survive untouched")
    }

    /// The authorities gate seam: with no discovery surface in the
    /// build layer (`discoveryEnabled: nil` — PR #246 standalone), the
    /// adapter is a pure legacy passthrough and never consults the
    /// catalog at all.
    func test_authorities_nilDiscoveryEnabledServesLegacyOnlyWithoutCatalogFanout() async throws {
        let catalog = DiscoverySeatCatalog(
            entries: { _ in
                XCTFail("no discovery surface present: the catalog must not be consulted")
                return []
            },
            fetchManifestBytes: { _ in
                XCTFail("no discovery surface present: no manifest may be fetched")
                throw URLError(.fileDoesNotExist)
            }
        )
        let fetcher = DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: catalog,
            fallback: StubAuthoritiesFallback(),
            discoveryEnabled: nil
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result, StubAuthoritiesFallback.sentinel)
    }

    func test_authorities_legacyFailureStillServesDiscoveredListings() async throws {
        struct FailingAuthoritiesFallback: KnownAuthoritiesFetcher {
            func fetchLatest() async throws -> [AuthorityListing] {
                throw URLError(.notConnectedToInternet)
            }
        }
        let seeded = try Self.seeded(
            componentId: "onym:component:test-authority",
            seatType: "moderation",
            manifestExtras: [
                "name": "Discovered Authority",
                "endpoints": [["uri": "https://authority.example/api"]],
            ]
        )
        let fetcher = DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: Self.catalog([seeded]),
            fallback: FailingAuthoritiesFallback(),
            discoveryEnabled: { true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Discovered Authority"])

        let emptyDiscovery = DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: Self.emptyCatalog,
            fallback: FailingAuthoritiesFallback(),
            discoveryEnabled: { true }
        )
        do {
            _ = try await emptyDiscovery.fetchLatest()
            XCTFail("with nothing discovered, the legacy failure must propagate")
        } catch {}
    }

    /// The LIVE authority manifest (authority.onym.app/manifest.json)
    /// declares `seat: "moderation"`; "authority" — the name the
    /// foundation docs use for the seat — is tolerated as an alias.
    func test_authorities_manifestSeatAuthorityAliasIsAccepted() async throws {
        let seeded = try Self.seeded(
            componentId: "onym:component:test-authority",
            seatType: "moderation",
            manifestExtras: [
                "name": "Alias Authority",
                "endpoints": [["uri": "https://authority.example/api"]],
            ],
            manifestSeatOverride: "authority"
        )
        let fetcher = DiscoveryBackedKnownAuthoritiesFetcher(
            catalog: Self.catalog([seeded]),
            fallback: StubAuthoritiesFallback(),
            discoveryEnabled: { true }
        )
        let result = try await fetcher.fetchLatest()
        XCTAssertEqual(result.map(\.name), ["Alias Authority", "Legacy Authority"])
    }

    // MARK: - wrapping(_:catalog:)

    func test_wrappingWithNilCatalogReturnsLegacyFetcherUnwrapped() async throws {
        let wrapped = DiscoveryBackedKnownRelayersFetcher.wrapping(
            StubRelayersFallback(),
            catalog: nil
        )
        XCTAssertTrue(wrapped is StubRelayersFallback)
        let result = try await wrapped.fetchLatest()
        XCTAssertEqual(result, StubRelayersFallback.sentinel)
    }
}
