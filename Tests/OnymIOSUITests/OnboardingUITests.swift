import XCTest

/// End-to-end walk of the first-launch onboarding cover under
/// `--ui-onboarding` + `--ui-discovery`: all seven steps, offline and
/// deterministic.
///
/// The discovery fakes serve the byte-pinned OnymDiscovery conformance
/// fixtures with the repository clock parked in the fixtures' validity
/// window (2026-08-14; snapshot expiry 2026-09-12 can't rot the test),
/// so step 2's TOFU confirm and step 3's module-consent walk run the
/// full production trust pipeline. The moderation fakes serve the
/// canned UITest Authority; `--moderation-needs-consent` starts the
/// mandate store empty so step 6 exercises the real pick → review →
/// sign path (mandatory: the directory has an entry, so Continue stays
/// locked until the mandate is signed).
///
/// A second launch WITHOUT `--reset-keychain` then proves persistence:
/// the completion flag survives, and the cover never re-presents even
/// though `--ui-onboarding` is still passed.
final class OnboardingUITests: XCTestCase {

    /// First 16 hex chars of the fixture operator key — duplicated
    /// from `UITestDiscoveryFixtures.operatorKeyFingerprint` on
    /// purpose (cross-bundle contract, same convention as
    /// `DiscoverySettingsUITests`).
    private let fingerprint = "ea4a 6c63 e29c 520a"

    /// The fixture snapshot's one catalog entry, as the aggregate row
    /// id embedded in the catalog rows' accessibility identifiers:
    /// `<providerId>|<catalogId>|<componentId>`.
    private let courierEntryId =
        "onym:component:onym-discovery|public-all-seats|onym:component:onym-courier"

    func test_onboardingWalk_allSevenSteps_thenNeverAgain() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-keychain",
            "--mock-biometric",
            "--ui-discovery",
            "--ui-onboarding",
            "--moderation-needs-consent",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()

        let onboarding = OnboardingScreen(app: app)

        // Step 1 — Welcome. Unskippable: no Skip affordance.
        XCTAssertTrue(onboarding.title("welcome").waitForExistence(timeout: 10),
                      "onboarding cover never presented. Hierarchy:\n\(app.debugDescription)")
        XCTAssertFalse(onboarding.skip("welcome").exists,
                       "welcome must not offer Skip")
        onboarding.continueFrom("welcome")

        // Step 2 — Discovery TOFU confirm. The seeded default source is
        // unpinned; Verify & Confirm fetches the fixture manifest and
        // shows the fixtures' operator-key fingerprint, byte-exact.
        XCTAssertTrue(onboarding.title("discoveryConfirm").waitForExistence(timeout: 5))
        XCTAssertTrue(onboarding.discoveryConfirmButton.waitForExistence(timeout: 5),
                      "seeded source's Verify & Confirm never appeared")
        onboarding.discoveryConfirmButton.tap()
        XCTAssertTrue(onboarding.discoveryFingerprint.waitForExistence(timeout: 5),
                      "TOFU fingerprint never appeared")
        XCTAssertEqual(onboarding.discoveryFingerprint.label, fingerprint,
                       "TOFU fingerprint must match the fixture operator key")
        onboarding.discoveryPinButton.tap()
        XCTAssertTrue(onboarding.discoveryAdded.waitForExistence(timeout: 5),
                      "provider-confirmed state never appeared")
        onboarding.continueFrom("discoveryConfirm")

        // Step 3 — Message transport. The seeded Onym Official relay is
        // preselected; the pinned provider's catalog offers the fixture
        // courier module — consent to it through the same sheet
        // Settings uses (offer preselected: courier-free-v1 is free).
        XCTAssertTrue(onboarding.title("messageTransport").waitForExistence(timeout: 5))
        XCTAssertTrue(
            onboarding.configuredRow(step: "messageTransport", url: "wss://nostr.onym.app")
                .waitForExistence(timeout: 5),
            "seeded default relay never appeared on the message-transport step"
        )
        let courierRow = onboarding.catalogRow(step: "messageTransport", entryId: courierEntryId)
        XCTAssertTrue(courierRow.waitForExistence(timeout: 10),
                      "fixture catalog entry never appeared. Hierarchy:\n\(app.debugDescription)")
        courierRow.tap()
        XCTAssertTrue(onboarding.consentAccept.waitForExistence(timeout: 5),
                      "module-consent sheet never appeared")
        // The reviewed manifest carries one free offer; Accept unlocks
        // once the review landed and the offer is preselected.
        XCTAssertTrue(waitUntilEnabled(onboarding.consentAccept, timeout: 5),
                      "Accept never became enabled")
        onboarding.consentAccept.tap()
        XCTAssertTrue(onboarding.consentDone.waitForExistence(timeout: 5),
                      "module-consent done state never appeared")
        onboarding.consentDismiss.tap()
        onboarding.continueFrom("messageTransport")

        // Step 4 — Blob transport. The seeded Onym Official Blossom
        // server renders as the ACTIVE pick; keep it.
        XCTAssertTrue(onboarding.title("blobTransport").waitForExistence(timeout: 5))
        XCTAssertTrue(
            onboarding.configuredRow(step: "blobTransport", url: "https://blossom.onym.app")
                .waitForExistence(timeout: 5),
            "seeded ACTIVE Blossom endpoint never appeared on the blob-transport step"
        )
        onboarding.continueFrom("blobTransport")

        // Step 5 — Notary. Auto-populate is suppressed during
        // onboarding, so the configuration starts empty and the
        // published list (UITest fixture fetcher) is the offer; add
        // the testnet relayer explicitly.
        XCTAssertTrue(onboarding.title("notary").waitForExistence(timeout: 5))
        let testnetRow = onboarding.notaryPublishedRow(url: "https://uitest-testnet-relayer.example")
        XCTAssertTrue(testnetRow.waitForExistence(timeout: 10),
                      "published notary row never appeared. Hierarchy:\n\(app.debugDescription)")
        testnetRow.tap()
        XCTAssertTrue(
            onboarding.configuredRow(
                step: "notary",
                url: "https://uitest-testnet-relayer.example"
            ).waitForExistence(timeout: 5),
            "added notary never appeared in the configured list"
        )
        onboarding.continueFrom("notary")

        // Step 6 — Moderation. Directory has the UITest Authority, so
        // the step is MANDATORY: Continue stays disabled and Skip never
        // appears until a mandate is signed.
        XCTAssertTrue(onboarding.title("moderation").waitForExistence(timeout: 5))
        let authorityRow = onboarding.moderationAuthorityRow(
            componentId: "onym:component:uitest-authority"
        )
        XCTAssertTrue(authorityRow.waitForExistence(timeout: 10),
                      "authority row never appeared. Hierarchy:\n\(app.debugDescription)")
        let moderationContinue = onboarding.primary("moderation")
        XCTAssertTrue(moderationContinue.waitForExistence(timeout: 5),
                      "moderation Continue button never appeared")
        XCTAssertFalse(moderationContinue.isEnabled,
                       "Continue must stay disabled before the mandate is signed")
        XCTAssertFalse(onboarding.skip("moderation").exists,
                       "moderation must not be skippable while the directory has entries")
        authorityRow.tap()
        XCTAssertTrue(onboarding.moderationAgree.waitForExistence(timeout: 5),
                      "manifest review (I agree and sign) never appeared")
        onboarding.moderationAgree.tap()
        XCTAssertTrue(onboarding.moderationDone.waitForExistence(timeout: 10),
                      "mandate-signed state never appeared")
        onboarding.continueFrom("moderation")

        // Step 7 — Done. Summary card renders; Start completes and the
        // cover dismisses onto the Chats tab.
        XCTAssertTrue(onboarding.title("done").waitForExistence(timeout: 5))
        XCTAssertTrue(onboarding.doneSummary.waitForExistence(timeout: 5),
                      "done summary card never appeared")
        onboarding.continueFrom("done")

        let chats = ChatsScreen(app: app)
        XCTAssertTrue(chats.chatsTab.waitForExistence(timeout: 10),
                      "app never landed on the tab bar after onboarding")
        XCTAssertFalse(onboarding.title("done").exists,
                       "onboarding cover should be dismissed after Start")

        // Second launch, same install, NO --reset-keychain: the
        // completion flag persisted, so the cover must not re-present
        // even with --ui-onboarding still passed.
        app.terminate()
        let second = XCUIApplication()
        second.launchArguments = [
            "--ui-testing",
            "--mock-biometric",
            "--ui-discovery",
            "--ui-onboarding",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        second.launch()
        let secondChats = ChatsScreen(app: second)
        XCTAssertTrue(secondChats.chatsTab.waitForExistence(timeout: 10),
                      "relaunch never reached the tab bar")
        XCTAssertFalse(
            OnboardingScreen(app: second).title("welcome").exists,
            "onboarding must not re-present once completed"
        )
    }

    /// `--skip-onboarding` outranks `--ui-onboarding`: launch a fresh
    /// install with BOTH flags (same posture as the walk test plus the
    /// veto) and the cover must never present. Passing both is what
    /// pins the veto's precedence — with `--ui-onboarding` absent the
    /// gate's first conjunct already yields false and the test would
    /// pass even without the veto.
    func test_skipOnboarding_neverPresentsCover() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-keychain",
            "--mock-biometric",
            "--ui-discovery",
            "--ui-onboarding",
            "--skip-onboarding",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        let chats = ChatsScreen(app: app)
        XCTAssertTrue(chats.chatsTab.waitForExistence(timeout: 10),
                      "app never reached the tab bar")
        XCTAssertFalse(OnboardingScreen(app: app).title("welcome").exists,
                       "onboarding must not present under --skip-onboarding")
    }

    /// Polls `isEnabled` — XCUIElement has no built-in wait for
    /// enablement, and the consent sheet enables Accept only after the
    /// (fast, offline) manifest review lands.
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists && element.isEnabled
    }
}
