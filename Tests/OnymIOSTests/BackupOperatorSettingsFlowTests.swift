import CryptoKit
import XCTest
@testable import OnymIOS
import OnymDiscovery
import OnymFoundation
import OnymSettings

/// Settings → Backup Operators, the surface that made the device-backup
/// seat reachable at all: without it nothing could ever write a
/// `storage.backup` consent record, so `BackupSeat.consentedManifests`
/// answered empty forever and the Device Backup section could not
/// appear.
///
/// The flow is the catalog half of the transport pickers with the
/// configured-list half removed — an operator is adopted by consent
/// and dropped by withdrawal, not by editing a configuration — so what
/// is tested here is what remains: the entries stream, the memoized
/// consent lookups, and the empty answer a build without discovery
/// must keep giving.
@MainActor
final class BackupOperatorSettingsFlowTests: XCTestCase {

    func test_start_drainsCatalogEntriesFromThePicker() async throws {
        let (entry, _) = try Self.consentedCatalogFixture()
        let flow = BackupOperatorSettingsFlow(
            discovery: DiscoveryModulePicker(
                entries: { [entry] },
                activeConsent: { _ in nil },
                makeConsentFlow: { _ in fatalError("not exercised") }
            )
        )
        flow.start()
        defer { flow.stop() }

        try await waitFor { !flow.catalogEntries.isEmpty }
        XCTAssertEqual(flow.catalogEntries.map(\.entry.componentId),
                       [entry.entry.componentId])
    }

    /// The badge on a row is the consent state of the exact bytes the
    /// catalog lists, and it is memoized per catalog install — the
    /// lookup decodes the whole consent store, far too heavy per row
    /// per render.
    func test_activeConsent_resolvesConsentedEntry() async throws {
        let (entry, record) = try Self.consentedCatalogFixture()
        let flow = BackupOperatorSettingsFlow(
            discovery: DiscoveryModulePicker(
                entries: { [entry] },
                activeConsent: { $0 == entry.entry.componentId ? record : nil },
                makeConsentFlow: { _ in fatalError("not exercised") }
            )
        )
        flow.start()
        defer { flow.stop() }

        try await waitFor { !flow.catalogEntries.isEmpty }
        XCTAssertEqual(flow.activeConsent(for: entry)?.manifestHash, record.manifestHash)
        XCTAssertEqual(flow.activeConsent(for: entry)?.manifestHash,
                       entry.entry.manifest.digest,
                       "same digest as the entry lists — the row renders CONSENTED, not TERMS CHANGED")
    }

    /// A consent pinned over OLDER bytes than the catalog now lists is
    /// the republish case: the record is present, its hash is not the
    /// entry's, and the row must be able to say TERMS CHANGED rather
    /// than reporting a consent to bytes nobody reviewed.
    func test_activeConsent_republishedEntry_keepsTheOldHash() async throws {
        let (entry, _) = try Self.consentedCatalogFixture()
        let (_, staleRecord) = try Self.consentedCatalogFixture(
            componentId: entry.entry.componentId,
            endpointURL: URL(string: "https://old.backup.example")!
        )
        let flow = BackupOperatorSettingsFlow(
            discovery: DiscoveryModulePicker(
                entries: { [entry] },
                activeConsent: { _ in staleRecord },
                makeConsentFlow: { _ in fatalError("not exercised") }
            )
        )
        flow.start()
        defer { flow.stop() }

        try await waitFor { !flow.catalogEntries.isEmpty }
        XCTAssertNotNil(flow.activeConsent(for: entry))
        XCTAssertNotEqual(flow.activeConsent(for: entry)?.manifestHash,
                          entry.entry.manifest.digest)
    }

    /// No discovery stack (the UI-test harness) keeps the flow
    /// permanently empty rather than crashing on a missing seam — the
    /// screen renders its "nothing listed" card, and the Settings row
    /// is not built at all in that build.
    func test_withoutDiscovery_staysEmpty() async throws {
        let flow = BackupOperatorSettingsFlow(discovery: nil)
        flow.start()
        defer { flow.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(flow.catalogEntries.isEmpty)
    }

    // MARK: - Catalog fixtures

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(of raw: Data) -> String {
        "sha256:" + hex(Data(SHA256.hash(data: raw)))
    }

    /// Raw bytes of a freshly signed backup-seat manifest. Signed for
    /// real because `ServiceManifestReviewer` is hard-enforced — there
    /// is no accept-anyway path to push a fixture through.
    private static func signedManifestRaw(
        key: Curve25519.Signing.PrivateKey,
        componentId: String,
        endpointURL: URL
    ) throws -> Data {
        var object: [String: Any] = [
            "componentId": componentId,
            "seat": "storage.backup",
            "operator": "onym:key:\(hex(key.publicKey.rawRepresentation))",
            "validUntil": "2030-01-01T00:00:00Z",
            "endpoints": [["uri": endpointURL.absoluteString, "role": "read-write"]],
        ]
        let unsigned = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let signature = try key.signature(for: ServiceManifestCanonical.signingBytes(of: unsigned))
        object["signature"] = signature.base64EncodedString()
        return try JSONSerialization.data(
            withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    /// A verified `storage.backup` catalog entry plus the pinned
    /// consent over the same bytes.
    private static func consentedCatalogFixture(
        componentId: String = "onym:component:test-backup",
        endpointURL: URL = URL(string: "https://backup.example")!
    ) throws -> (AttributedCatalogEntry, PinnedConsentRecord) {
        let key = Curve25519.Signing.PrivateKey()
        let raw = try signedManifestRaw(
            key: key, componentId: componentId, endpointURL: endpointURL)
        let reviewed = try ServiceManifestReviewer().review(
            raw: raw, expectedDigest: digest(of: raw))
        let record = PinnedConsentRecord(reviewed: reviewed, acceptedAt: Date())
        let entryJSON: [String: Any] = [
            "componentId": componentId,
            "seatType": "storage.backup",
            "manifest": [
                "uri": "https://provider.example/manifests/backup.json",
                "digest": digest(of: raw),
            ],
            "operator": "onym:key:\(hex(key.publicKey.rawRepresentation))",
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
        return (
            AttributedCatalogEntry(
                entry: entry,
                source: SourceAttribution(
                    providerId: "onym:component:test-provider",
                    sourceLabel: "Test Provider",
                    catalogId: "public",
                    snapshotDigest: "sha256:" + String(repeating: "0", count: 64),
                    relationship: "none",
                    placement: "neutral"
                )
            ),
            record
        )
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out", file: file, line: line)
    }
}
