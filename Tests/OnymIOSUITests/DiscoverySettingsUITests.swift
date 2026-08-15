import XCTest

/// End-to-end UI test for Settings → Discovery under `--ui-discovery`:
/// the app serves the byte-pinned OnymDiscovery conformance fixtures
/// through `UITestDiscoveryFetcher`, so the full production trust
/// pipeline (TOFU preview → key pin → snapshot verification) runs
/// offline and deterministically.
///
/// The walk: the seeded default source starts UNCONFIRMED (no pinned
/// key — hard enforcement means it contributes nothing yet); its
/// "Confirm…" opens the TOFU sheet, whose fingerprint must be exactly
/// the fixtures' operator key; pinning it triggers the targeted
/// refresh that verifies and retains the fixture snapshot; back on the
/// list, the row shows the pinned key and the verified catalog entry
/// count.
final class DiscoverySettingsUITests: XCTestCase {

    /// First 16 hex chars of the fixture operator key, grouped as the
    /// TOFU screen renders it — duplicated from
    /// `UITestDiscoveryFixtures.operatorKeyFingerprint` so a fixture
    /// regeneration forces a fix here too (cross-bundle contract, same
    /// convention as `RelayerSettingsUITests`' fixture URLs).
    private let fingerprint = "ea4a 6c63 e29c 520a"

    func test_confirmDefaultSource_pinsKeyAndRendersCatalogEntries() throws {
        let app = AppLauncher.launchFresh(discovery: true)
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.waitForReady())

        let discovery = DiscoverySettingsScreen(app: app)
        discovery.open()

        // The seeded default source is listed, unconfirmed.
        XCTAssertTrue(discovery.defaultSourceRow.waitForExistence(timeout: 5),
                      "seeded default discovery source never appeared")
        XCTAssertTrue(discovery.confirmSourceButton.waitForExistence(timeout: 5),
                      "unconfirmed default source should offer Confirm…")
        discovery.confirmSourceButton.tap()

        // TOFU sheet: the fingerprint is the fixtures' operator key.
        XCTAssertTrue(discovery.fingerprint.waitForExistence(timeout: 5),
                      "TOFU fingerprint never appeared")
        XCTAssertEqual(discovery.fingerprint.label, fingerprint,
                       "TOFU fingerprint must match the fixture operator key")

        // Pin the key. The confirm runs a targeted refresh that
        // fetches + verifies the fixture snapshot.
        discovery.pinConfirmButton.tap()
        XCTAssertTrue(discovery.addDone.waitForExistence(timeout: 5),
                      "provider-added state never appeared")
        discovery.dismissSheetButton.tap()

        // Back on the list: the source row shows the pinned key…
        XCTAssertTrue(app.staticTexts["Key \(fingerprint)"].waitForExistence(timeout: 5),
                      "source row should show the pinned key fingerprint")
        // …and the verified fixture snapshot's single entry counts in.
        let entryCount = discovery.entryCountText(1)
        if !entryCount.waitForExistence(timeout: 5) {
            XCTFail("source row should count the verified catalog entry. Hierarchy:\n\(app.debugDescription)")
        }
    }
}
