import XCTest
@testable import OnymIOS
import OnymDiscovery
import OnymFoundation
import OnymTransportBlossom

/// The blossom catalog picker's consent-`apply` step
/// (`BlossomCatalogConsent.apply`): https-endpoint extraction, display
/// naming, and — the part that made the pick real instead of silently
/// inert — ORDERING: the consented server must land FIRST, ahead of
/// the seeded default, because uploads/downloads only ever target
/// `currentEndpoints().first`.
final class BlossomCatalogConsentTests: XCTestCase {

    func test_apply_placesPickedServerFirst_keepsSeededDefault() async throws {
        // Fresh first-launch repository: Onym Official seeded at head.
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)

        let manifest = try Self.manifest(
            name: "Picked Blobs",
            endpoints: ["https://blobs.picked.example"]
        )
        try await BlossomCatalogConsent.apply(manifest: manifest, to: repo)

        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.first?.url.absoluteString, "https://blobs.picked.example",
                       "the consented pick must become the ACTIVE (first) server")
        XCTAssertEqual(endpoints.first?.name, "Picked Blobs")
        XCTAssertEqual(endpoints.first?.isDefault, false,
                       "a consent pick is the user's choice, not a published default")
        XCTAssertEqual(endpoints.count, 2)
        XCTAssertEqual(endpoints.last?.url.absoluteString, "https://blossom.onym.app",
                       "the seeded default stays configured behind the pick")
        XCTAssertTrue(store.load().hasUserInteracted,
                      "the pick counts as user interaction so refreshes never clobber it")
    }

    func test_apply_prefersFirstHttpsEndpoint_skipsOtherSchemes() async throws {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)

        let manifest = try Self.manifest(
            name: "Mixed",
            endpoints: ["wss://relay.example", "https://first.example", "https://second.example"]
        )
        try await BlossomCatalogConsent.apply(manifest: manifest, to: repo)

        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.first?.url.absoluteString, "https://first.example",
                       "first https endpoint in published order wins")
    }

    func test_apply_noHttpsEndpoint_throwsAndLeavesConfigurationUntouched() async throws {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)

        let manifest = try Self.manifest(name: "Wss only", endpoints: ["wss://relay.example"])
        do {
            try await BlossomCatalogConsent.apply(manifest: manifest, to: repo)
            XCTFail("expected ModuleApplyError.noUsableEndpoint")
        } catch let error as ModuleApplyError {
            XCTAssertEqual(error, .noUsableEndpoint)
        }

        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.map(\.url.absoluteString), ["https://blossom.onym.app"],
                       "a failed apply must not touch the configuration")
        XCTAssertFalse(store.load().hasUserInteracted)
    }

    func test_apply_missingName_fallsBackToShortComponentId() async throws {
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)

        let manifest = try Self.manifest(name: nil, endpoints: ["https://anon.example"])
        try await BlossomCatalogConsent.apply(manifest: manifest, to: repo)

        let endpoints = await repo.currentEndpoints()
        let expected = await MainActor.run {
            ModuleConsentFlow.shortComponentId("onym:component:test-blobs")
        }
        XCTAssertEqual(endpoints.first?.name, expected,
                       "no published name falls back to the short component id")
    }

    func test_apply_reappliedAfterDemotion_promotesBackToFirst() async throws {
        // Consent once, user later makes another server active, then
        // re-runs the consent apply (e.g. re-consents from the catalog
        // row) — the pick must promote back to the head, not duplicate.
        let store = InMemoryBlossomServersSelectionStore(initial: .empty)
        let repo = BlossomServersRepository(store: store)
        let manifest = try Self.manifest(name: "Picked", endpoints: ["https://picked.example"])

        try await BlossomCatalogConsent.apply(manifest: manifest, to: repo)
        await repo.makeActive(url: URL(string: "https://blossom.onym.app")!)
        try await BlossomCatalogConsent.apply(manifest: manifest, to: repo)

        let endpoints = await repo.currentEndpoints()
        XCTAssertEqual(endpoints.map(\.url.absoluteString),
                       ["https://picked.example", "https://blossom.onym.app"],
                       "re-apply promotes the existing row, no duplicates")
    }

    // MARK: - helpers

    /// Minimal signed-manifest spine + blob-storage fields. No
    /// signature verification happens in `SignedServiceManifest(raw:)`
    /// or the apply step — review already ran upstream in the flow.
    private static func manifest(
        name: String?,
        endpoints: [String],
        componentId: String = "onym:component:test-blobs"
    ) throws -> SignedServiceManifest {
        var object: [String: Any] = [
            "componentId": componentId,
            "seat": "blob.storage",
            "operator": "onym:key:" + String(repeating: "ab", count: 32),
            "validUntil": "2030-01-01T00:00:00Z",
            "endpoints": endpoints.map { ["uri": $0, "role": "read-write"] },
        ]
        if let name { object["name"] = name }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        return try SignedServiceManifest(raw: bytes)
    }
}
