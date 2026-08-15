import CryptoKit
import XCTest
@testable import OnymIOS
import OnymChain
import OnymDiscovery
import OnymFoundation
import OnymSettings

/// Settings flow against a real `RelayerRepository` backed by the
/// in-memory store + fake fetcher. Asserts intent dispatch
/// (add / remove / setPrimary / setStrategy / addCustom), the
/// local-only custom-URL draft + validation, and the
/// `unconfiguredKnownList` filter that hides published entries the
/// user has already added.
@MainActor
final class RelayerSettingsFlowTests: XCTestCase {
    private let testEndpoint = RelayerEndpoint(
        name: "Test",
        url: URL(string: "https://relayer-test.example")!,
        networks: ["testnet"]
    )

    private func makeFlow(
        store: InMemoryRelayerSelectionStore? = nil,
        fetcherMode: FakeKnownRelayersFetcher.Mode = .succeeds([])
    ) -> (RelayerSettingsFlow, RelayerRepository, InMemoryRelayerSelectionStore) {
        let resolvedStore = store ?? InMemoryRelayerSelectionStore()
        let fetcher = FakeKnownRelayersFetcher(mode: fetcherMode)
        let repo = RelayerRepository(fetcher: fetcher, store: resolvedStore)
        let flow = RelayerSettingsFlow(repository: repo)
        return (flow, repo, resolvedStore)
    }

    // MARK: - tappedAddKnown

    func test_tappedAddKnown_addsViaRepository() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.tappedAddKnown(testEndpoint)
        try await waitFor { store.loadConfiguration().endpoints == [self.testEndpoint] }
    }

    // MARK: - custom URL draft

    func test_customDraftChanged_updatesStateAndClearsError() {
        let (flow, _, _) = makeFlow()
        flow.tappedAddCustom()  // empty draft → sets error
        XCTAssertNotNil(flow.state.customDraftError)

        flow.customDraftChanged("https://x.com")
        XCTAssertEqual(flow.state.customDraft, "https://x.com")
        XCTAssertNil(flow.state.customDraftError)
    }

    func test_tappedAddCustom_validURL_addsAsCustomEndpointAndClearsDraft() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.customDraftChanged("https://my-relayer.dev")
        flow.tappedAddCustom()

        try await waitFor { !store.loadConfiguration().endpoints.isEmpty }
        let endpoint = store.loadConfiguration().endpoints.first
        XCTAssertEqual(endpoint?.url, URL(string: "https://my-relayer.dev"))
        XCTAssertEqual(endpoint?.networks, [RelayerEndpoint.customNetwork])
        XCTAssertEqual(endpoint?.name, "my-relayer.dev",
                       "custom endpoint name defaults to the URL host")
        XCTAssertEqual(flow.state.customDraft, "",
                       "successful add must clear the draft so the field is ready for the next entry")
    }

    func test_tappedAddCustom_emptyDraft_setsErrorAndDoesNotAdd() {
        let (flow, _, store) = makeFlow()
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertTrue(store.loadConfiguration().endpoints.isEmpty)
    }

    func test_tappedAddCustom_garbageDraft_setsErrorAndDoesNotAdd() {
        let (flow, _, store) = makeFlow()
        flow.customDraftChanged("not-a-url at all")
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertTrue(store.loadConfiguration().endpoints.isEmpty)
    }

    func test_tappedAddCustom_ftpScheme_setsErrorAndDoesNotAdd() {
        let (flow, _, store) = makeFlow()
        flow.customDraftChanged("ftp://relayer.example.com")
        flow.tappedAddCustom()
        XCTAssertNotNil(flow.state.customDraftError)
        XCTAssertTrue(store.loadConfiguration().endpoints.isEmpty)
    }

    func test_tappedAddCustom_trimsWhitespace() async throws {
        let (flow, _, store) = makeFlow()
        flow.start()
        defer { flow.stop() }

        flow.customDraftChanged("   https://relayer.example.com  \n")
        flow.tappedAddCustom()
        try await waitFor { !store.loadConfiguration().endpoints.isEmpty }
        XCTAssertEqual(
            store.loadConfiguration().endpoints.first?.url,
            URL(string: "https://relayer.example.com")
        )
    }

    // MARK: - tappedRemove / tappedSetPrimary / tappedStrategy

    func test_tappedRemove_removesViaRepository() async throws {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedRemove(url: testEndpoint.url)
        try await waitFor { store.loadConfiguration().endpoints.isEmpty }
    }

    func test_tappedSetPrimary_marksViaRepository() async throws {
        let other = RelayerEndpoint(name: "Other", url: URL(string: "https://other.example")!, networks: ["testnet"])
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint, other], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedSetPrimary(url: other.url)
        try await waitFor { store.loadConfiguration().primaryURL == other.url }
    }

    func test_tappedStrategy_setsViaRepository() async throws {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        flow.tappedStrategy(.random)
        try await waitFor { store.loadConfiguration().strategy == .random }
    }

    // MARK: - read helpers

    func test_unconfiguredKnownList_hidesAlreadyConfiguredURLs() async throws {
        let known = [
            testEndpoint,
            RelayerEndpoint(name: "Other", url: URL(string: "https://other.example")!, networks: ["public"])
        ]
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: nil, strategy: .primary),
            cachedList: known
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }

        try await waitFor { !flow.state.snapshot.knownList.isEmpty }
        let remaining = flow.unconfiguredKnownList
        XCTAssertEqual(remaining.map(\.url), [URL(string: "https://other.example")],
                       "endpoints already in the configured list must not appear in the add-from-known list")
    }

    func test_isPrimary_reflectsConfiguration() async throws {
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [testEndpoint], primaryURL: testEndpoint.url, strategy: .primary)
        )
        let (flow, _, _) = makeFlow(store: store)
        flow.start()
        defer { flow.stop() }
        try await waitFor { flow.state.snapshot.configuration.primaryURL != nil }
        XCTAssertTrue(flow.isPrimary(testEndpoint))
    }

    /// The consent-derived dedupe: a published-list row whose URL is
    /// an endpoint of a CONSENTED catalog entry's pinned manifest is
    /// hidden — that service renders in the "From catalog" section
    /// with attribution and consent state instead. Keyed off the
    /// catalog entries + consent records the flow already holds, not
    /// a fetch-time registry, so it can't race the known list
    /// rendering from cache before any fetch.
    func test_unconfiguredKnownList_hidesConsentedCatalogEndpointURLs() async throws {
        let consentedURL = URL(string: "https://consented.example/api")!
        let (entry, record) = try Self.consentedCatalogFixture(endpointURL: consentedURL)
        let known = [
            RelayerEndpoint(name: "Consented", url: consentedURL, networks: ["testnet"]),
            RelayerEndpoint(name: "Other", url: URL(string: "https://other.example")!, networks: ["public"]),
        ]
        let store = InMemoryRelayerSelectionStore(
            configuration: RelayerConfiguration(endpoints: [], primaryURL: nil, strategy: .primary),
            cachedList: known
        )
        let fetcher = FakeKnownRelayersFetcher(mode: .succeeds(known))
        let repo = RelayerRepository(fetcher: fetcher, store: store)
        let discovery = DiscoveryModulePicker(
            entries: { [entry] },
            activeConsent: { $0 == entry.entry.componentId ? record : nil },
            makeConsentFlow: { _ in fatalError("not exercised") }
        )
        let flow = RelayerSettingsFlow(repository: repo, discovery: discovery)
        flow.start()
        defer { flow.stop() }

        try await waitFor { !flow.state.snapshot.knownList.isEmpty && !flow.catalogEntries.isEmpty }
        XCTAssertEqual(
            flow.unconfiguredKnownList.map(\.url), [URL(string: "https://other.example")],
            "a consented catalog endpoint must render in the catalog section, not as a bare published row"
        )
    }

    /// The fix-1 regression at the SCREEN level (the reviewed
    /// duplicate-row bug): an operator republished — the ACTIVE
    /// consent record pins the OLD manifest bytes while the catalog
    /// entry now lists a NEW digest with a NEW endpoint URL. The
    /// catalog row renders in its TERMS CHANGED state (record present,
    /// hash != entry digest), and because the adapter's consent gate
    /// compares digests, the new URL never enters the known list — so
    /// the published section must NOT offer it as a bare tap-to-add
    /// row next to the TERMS CHANGED catalog row.
    func test_unconfiguredKnownList_termsChangedEntryDoesNotOfferNewURLAsPublishedRow() async throws {
        struct LegacyStub: KnownRelayersFetcher {
            let list: [RelayerEndpoint]
            func fetchLatest() async throws -> [RelayerEndpoint] { list }
        }
        let componentId = "onym:component:republished-notary"
        let key = Curve25519.Signing.PrivateKey()
        let oldRaw = try Self.signedManifestRaw(
            key: key, componentId: componentId,
            endpointURL: URL(string: "https://old.example/api")!
        )
        let newURL = URL(string: "https://new.example/api")!
        let newRaw = try Self.signedManifestRaw(
            key: key, componentId: componentId, endpointURL: newURL
        )
        // Consent pins the OLD bytes; the catalog lists the NEW digest.
        let reviewedOld = try ServiceManifestReviewer().review(
            raw: oldRaw, expectedDigest: Self.digest(of: oldRaw)
        )
        let record = PinnedConsentRecord(reviewed: reviewedOld, acceptedAt: Date())
        let entry = try Self.attributedEntry(
            componentId: componentId,
            keyHex: Self.hex(key.publicKey.rawRepresentation),
            digest: Self.digest(of: newRaw)
        )
        XCTAssertNotEqual(
            record.manifestHash, entry.entry.manifest.digest,
            "fixture must model a republish: pinned hash differs from the listed digest"
        )

        let legacy = RelayerEndpoint(
            name: "Other", url: URL(string: "https://other.example")!, networks: ["public"]
        )
        let activeHashes = [componentId: record.manifestHash]
        let fetcher = DiscoveryBackedKnownRelayersFetcher(
            catalog: DiscoverySeatCatalog(
                entries: { seatType in seatType == "notary" ? [entry] : [] },
                fetchManifestBytes: { _ in newRaw }
            ),
            fallback: LegacyStub(list: [legacy]),
            // The app-shaped gate: componentId AND digest must match
            // the active record.
            makeConsentGate: { { id, digest in activeHashes[id] == digest } }
        )
        // `hasUserInteracted` (the init default) so the refresh below
        // exercises the known-list path, not first-launch
        // auto-populate — a populated config would hide every row from
        // `unconfiguredKnownList` regardless of the gate.
        let repo = RelayerRepository(
            fetcher: fetcher,
            store: InMemoryRelayerSelectionStore(
                configuration: RelayerConfiguration(endpoints: [], primaryURL: nil, strategy: .primary)
            )
        )
        let discovery = DiscoveryModulePicker(
            entries: { [entry] },
            activeConsent: { $0 == componentId ? record : nil },
            makeConsentFlow: { _ in fatalError("not exercised") }
        )
        let flow = RelayerSettingsFlow(repository: repo, discovery: discovery)
        flow.start()
        defer { flow.stop() }
        try? await repo.refresh()
        try await waitFor { !flow.state.snapshot.knownList.isEmpty && !flow.catalogEntries.isEmpty }

        // The catalog row is present, in its TERMS CHANGED condition
        // (active record whose hash no longer matches the digest).
        let rowRecord = try XCTUnwrap(flow.activeConsent(for: entry))
        XCTAssertNotEqual(rowRecord.manifestHash, entry.entry.manifest.digest)
        // …and the published section does not offer the unreviewed
        // new endpoint: the digest-comparing gate kept it out of the
        // known list entirely, closing the duplicate-row hole.
        XCTAssertEqual(
            flow.unconfiguredKnownList.map(\.url), [legacy.url],
            "the republished manifest's new URL must not render as a bare tap-to-add published row"
        )
        XCTAssertFalse(flow.state.snapshot.knownList.contains { $0.url == newURL })
    }

    // MARK: - Catalog fixtures

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(of raw: Data) -> String {
        "sha256:" + hex(Data(SHA256.hash(data: raw)))
    }

    /// Raw bytes of a freshly signed notary manifest with one endpoint.
    private static func signedManifestRaw(
        key: Curve25519.Signing.PrivateKey,
        componentId: String,
        endpointURL: URL
    ) throws -> Data {
        var object: [String: Any] = [
            "componentId": componentId,
            "seat": "notary",
            "operator": "onym:key:\(hex(key.publicKey.rawRepresentation))",
            "validUntil": "2030-01-01T00:00:00Z",
            "endpoints": [["uri": endpointURL.absoluteString]],
        ]
        let unsigned = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let signature = try key.signature(for: ServiceManifestCanonical.signingBytes(of: unsigned))
        object["signature"] = signature.base64EncodedString()
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    /// A verified catalog entry (notary seat) listing `digest` under
    /// `componentId`, wrapped in test attribution.
    private static func attributedEntry(
        componentId: String,
        keyHex: String,
        digest: String
    ) throws -> AttributedCatalogEntry {
        let entryJSON: [String: Any] = [
            "componentId": componentId,
            "seatType": "notary",
            "manifest": ["uri": "https://provider.example/manifests/consented.json", "digest": digest],
            "operator": "onym:key:\(keyHex)",
            "listedAt": "2026-01-01T00:00:00Z",
            "relationship": "none",
            "placement": "neutral",
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(
            CatalogEntry.self,
            from: JSONSerialization.data(withJSONObject: entryJSON)
        )
        return AttributedCatalogEntry(
            entry: entry,
            source: SourceAttribution(
                providerId: "onym:component:test-provider",
                sourceLabel: "Test Provider",
                catalogId: "public",
                snapshotDigest: "sha256:" + String(repeating: "0", count: 64),
                relationship: "none",
                placement: "neutral"
            )
        )
    }

    /// A reviewed + pinned consent over a freshly signed manifest with
    /// one endpoint URI, plus the matching catalog entry.
    private static func consentedCatalogFixture(
        endpointURL: URL
    ) throws -> (AttributedCatalogEntry, PinnedConsentRecord) {
        let key = Curve25519.Signing.PrivateKey()
        let raw = try signedManifestRaw(
            key: key, componentId: "onym:component:consented-notary", endpointURL: endpointURL
        )
        let reviewed = try ServiceManifestReviewer().review(raw: raw, expectedDigest: digest(of: raw))
        let record = PinnedConsentRecord(reviewed: reviewed, acceptedAt: Date())
        let entry = try attributedEntry(
            componentId: "onym:component:consented-notary",
            keyHex: hex(key.publicKey.rawRepresentation),
            digest: digest(of: raw)
        )
        return (entry, record)
    }

    // MARK: - validate

    func test_validate_acceptsHTTPS() {
        XCTAssertNotNil(RelayerSettingsFlow.validate("https://relayer.example.com"))
    }

    func test_validate_acceptsHTTPForLocalhost() {
        XCTAssertNotNil(RelayerSettingsFlow.validate("http://localhost:8080"))
    }

    func test_validate_rejectsEmpty() {
        XCTAssertNil(RelayerSettingsFlow.validate(""))
    }

    func test_validate_rejectsMissingScheme() {
        XCTAssertNil(RelayerSettingsFlow.validate("relayer.example.com"))
    }

    func test_validate_rejectsMissingHost() {
        XCTAssertNil(RelayerSettingsFlow.validate("https://"))
    }

    // MARK: - helpers

    private func waitFor(
        timeoutMs: Int = 1000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while !condition() {
            if Date() > deadline {
                XCTFail("waitFor timed out after \(timeoutMs)ms")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
