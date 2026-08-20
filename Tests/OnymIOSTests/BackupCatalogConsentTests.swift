import XCTest
@testable import OnymIOS
import OnymBackup
import OnymDiscovery
import OnymFoundation

/// The backup catalog picker's consent-`apply` step
/// (`BackupCatalogConsent.apply`) and the signal it raises.
///
/// Apply writes nothing here — the pinned consent record is the
/// enrolment, and `BackupSeat.consentedManifests` reads it directly —
/// so the behavior worth locking down is the REFUSAL: a manifest the
/// backup seat cannot use must stop the flow, because the alternative
/// is a "Service added" screen followed by a Device Backup section
/// that never appears.
final class BackupCatalogConsentTests: XCTestCase {

    func test_apply_usableManifest_succeeds() throws {
        let manifest = try Self.manifest()
        XCTAssertNoThrow(try BackupCatalogConsent.apply(manifest: manifest))
    }

    /// The `ModuleApplyError.noUsableEndpoint` translation: this is the
    /// one refusal the consent flow renders with its honest two-part
    /// message ("your consent was recorded, but it wasn't added"),
    /// which is exactly what happened.
    func test_apply_noReadWriteEndpoint_throwsNoUsableEndpoint() throws {
        let manifest = try Self.manifest(
            endpoints: [["uri": "https://backup.example", "role": "read-only"]]
        )
        do {
            try BackupCatalogConsent.apply(manifest: manifest)
            XCTFail("expected ModuleApplyError.noUsableEndpoint")
        } catch let error as ModuleApplyError {
            XCTAssertEqual(error, .noUsableEndpoint)
        }
    }

    /// Same refusal for the scheme, and for the same reason a Nostr
    /// relay refuses a manifest without `wss`: a sealed snapshot does
    /// not go over plaintext http, and nothing here rewrites an
    /// endpoint into something that would work.
    func test_apply_httpEndpoint_throwsNoUsableEndpoint() throws {
        let manifest = try Self.manifest(
            endpoints: [["uri": "http://backup.example", "role": "read-write"]]
        )
        do {
            try BackupCatalogConsent.apply(manifest: manifest)
            XCTFail("expected ModuleApplyError.noUsableEndpoint")
        } catch let error as ModuleApplyError {
            XCTAssertEqual(error, .noUsableEndpoint)
        }
    }

    /// A read-write entry that is malformed does not condemn the
    /// manifest while a usable one sits behind it — `BackupOperatorManifest`
    /// binds to the first USABLE entry, and apply must not be stricter
    /// than the parser every other read of this record goes through.
    func test_apply_skipsMalformedEndpointAndBindsToTheUsableOne() throws {
        let manifest = try Self.manifest(endpoints: [
            ["uri": "not a url at all", "role": "read-write"],
            ["uri": "https://backup.example", "role": "read-write"],
        ])
        XCTAssertNoThrow(try BackupCatalogConsent.apply(manifest: manifest))
    }

    /// Not every refusal is an endpoint. A profile this build does not
    /// implement is rethrown as itself rather than dressed up as a
    /// missing endpoint, which would send somebody looking at a URL
    /// that is perfectly fine.
    func test_apply_unsupportedProfile_rethrowsBackupError() throws {
        let manifest = try Self.manifest(backupProfileId: "onym:backup-profile:something-else-v9")
        do {
            try BackupCatalogConsent.apply(manifest: manifest)
            XCTFail("expected BackupError.unsupportedProfile")
        } catch let error as BackupError {
            XCTAssertEqual(error, .unsupportedProfile)
        }
    }

    /// Terms are a precondition of enrolment, so a manifest that
    /// declares none can never be backed up to. Also rethrown as
    /// itself.
    func test_apply_missingDeclaredTerms_rethrowsBackupError() throws {
        let manifest = try Self.manifest(declaredTerms: nil)
        do {
            try BackupCatalogConsent.apply(manifest: manifest)
            XCTFail("expected BackupError.termsUnavailable")
        } catch let error as BackupError {
            XCTAssertEqual(error, .termsUnavailable)
        }
    }

    /// The manifests apply accepts are exactly the ones
    /// `BackupSeat.consentedManifests` will later parse out of the
    /// pinned record. If these two ever disagree, a person is told the
    /// operator was added and then finds no section — the failure this
    /// whole step exists to prevent.
    func test_apply_acceptsExactlyWhatTheSeatCanLaterParse() throws {
        let usable = try Self.manifest()
        let unusable = try Self.manifest(
            endpoints: [["uri": "https://backup.example", "role": "read-only"]]
        )
        XCTAssertNoThrow(try BackupCatalogConsent.apply(manifest: usable))
        XCTAssertNotNil(try? BackupOperatorManifest(manifest: usable))
        XCTAssertThrowsError(try BackupCatalogConsent.apply(manifest: unusable))
        XCTAssertNil(try? BackupOperatorManifest(manifest: unusable))
    }

    // MARK: - Consent signal

    @MainActor
    func test_consentSignal_countsEveryConsent() {
        let signal = BackupConsentSignal()
        XCTAssertEqual(signal.revision, 0)
        signal.consentRecorded()
        let afterFirst = signal.revision
        signal.consentRecorded()
        XCTAssertNotEqual(signal.revision, afterFirst,
                          "a counter, not a flag — two consents must be two changes for onChange")
    }

    // MARK: - helpers

    /// A backup-seat manifest spine with the fields
    /// `BackupOperatorManifest` reads. No signature verification runs
    /// in `SignedServiceManifest(raw:)` or in the apply step — review
    /// already ran upstream in `ModuleConsentFlow`.
    private static func manifest(
        componentId: String = "onym:component:test-backup",
        endpoints: [[String: Any]] = [["uri": "https://backup.example", "role": "read-write"]],
        backupProfileId: String = BackupProfile.portableProfileId,
        declaredTerms: String? = "sha256:" + String(repeating: "9", count: 64),
        capabilities: [String] = ["upload", "list", "download", "erase", "export"]
    ) throws -> SignedServiceManifest {
        var object: [String: Any] = [
            "version": 1,
            "componentId": componentId,
            "seat": "storage.backup",
            "operator": "onym:key:" + String(repeating: "ab", count: 32),
            "validUntil": "2030-01-01T00:00:00Z",
            "backupProfileId": backupProfileId,
            "implementationProfileId": BackupProfile.implementationProfileId,
            "endpoints": endpoints,
            "capabilities": capabilities,
        ]
        if let declaredTerms { object["declaredTerms"] = declaredTerms }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        return try SignedServiceManifest(raw: bytes)
    }
}
