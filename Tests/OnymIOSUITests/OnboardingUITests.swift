import XCTest

/// End-to-end walk of the first-launch onboarding cover under
/// `--ui-onboarding` + `--ui-discovery`: the redesigned flow —
/// welcome → identity → services (through the "Choose services
/// myself" hub) → moderation → recovery phrase → done — offline and
/// deterministic.
///
/// The discovery fakes serve the byte-pinned OnymDiscovery conformance
/// fixtures with the repository clock parked in the fixtures' validity
/// window (2026-08-14; snapshot expiry 2026-09-12 can't rot the test),
/// so the hub's Directory TOFU confirm and Message-delivery
/// module-consent walk run the full production trust pipeline. The
/// moderation fakes serve the canned UITest Authority;
/// `--moderation-needs-consent` starts the mandate store empty so the
/// Reports & safety step exercises the real pick → review → sign path
/// (mandatory: the directory has an entry, so Continue stays locked
/// until the mandate is signed).
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

    func test_onboardingWalk_customServicesPath_thenNeverAgain() throws {
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

        // Step 1 — Welcome. Unskippable: no Skip affordance; the
        // primary reads "Create my identity".
        XCTAssertTrue(onboarding.title("welcome").waitForExistence(timeout: 10),
                      "onboarding cover never presented. Hierarchy:\n\(app.debugDescription)")
        XCTAssertFalse(onboarding.skip("welcome").exists,
                       "welcome must not offer Skip")
        onboarding.continueFrom("welcome")

        // Step 2 — Identity ("Making your keys", 1 of 3). The
        // checklist surfaces the silent bootstrap; informational.
        XCTAssertTrue(onboarding.title("identity").waitForExistence(timeout: 5))
        XCTAssertFalse(onboarding.skip("identity").exists,
                       "identity must not offer Skip")
        onboarding.continueFrom("identity")

        // Step 3 — Services (2 of 3). The recommended card is
        // preselected; take the "Choose services myself" branch so the
        // walk exercises the hub and every seat surface.
        XCTAssertTrue(onboarding.title("services").waitForExistence(timeout: 5))
        XCTAssertTrue(onboarding.servicesRecommendedCard.waitForExistence(timeout: 5),
                      "recommended-setup card never appeared")
        onboarding.servicesCustomCard.tap()
        XCTAssertTrue(onboarding.hubDone.waitForExistence(timeout: 5),
                      "services hub never presented. Hierarchy:\n\(app.debugDescription)")

        // Hub → Directory first: TOFU-confirm the seeded source so the
        // other seats' catalogs have a pinned provider to draw from.
        onboarding.hubRow("directory").tap()
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
        onboarding.hubBack()

        // Hub → Message delivery. The seeded Onym Official relay is
        // in use; the pinned provider's catalog offers the fixture
        // courier module — consent to it through the same sheet
        // Settings uses (offer preselected: courier-free-v1 is free).
        onboarding.hubRow("messageDelivery").tap()
        XCTAssertTrue(
            onboarding.configuredRow(step: "messageTransport", url: "wss://nostr.onym.app")
                .waitForExistence(timeout: 5),
            "seeded default relay never appeared on the message-delivery screen"
        )
        let courierRow = onboarding.catalogRow(step: "messageTransport", entryId: courierEntryId)
        XCTAssertTrue(courierRow.waitForExistence(timeout: 10),
                      "fixture catalog entry never appeared. Hierarchy:\n\(app.debugDescription)")
        courierRow.tap()
        XCTAssertTrue(onboarding.consentAccept.waitForExistence(timeout: 5),
                      "module-consent sheet never appeared")
        XCTAssertTrue(waitUntilEnabled(onboarding.consentAccept, timeout: 5),
                      "Accept never became enabled")
        onboarding.consentAccept.tap()
        XCTAssertTrue(onboarding.consentDone.waitForExistence(timeout: 5),
                      "module-consent done state never appeared")
        onboarding.consentDismiss.tap()
        onboarding.hubBack()

        // Hub → Media delivery. The seeded Onym Official Blossom
        // server renders as the ACTIVE pick; keep it.
        onboarding.hubRow("mediaDelivery").tap()
        XCTAssertTrue(
            onboarding.configuredRow(step: "blobTransport", url: "https://blossom.onym.app")
                .waitForExistence(timeout: 5),
            "seeded ACTIVE Blossom endpoint never appeared on the media-delivery screen"
        )
        onboarding.hubBack()

        // Hub → Group integrity. Auto-populate is suppressed during
        // onboarding, so the configuration starts empty and the
        // published list (UITest fixture fetcher) is the offer; add
        // the testnet relayer explicitly.
        onboarding.hubRow("groupIntegrity").tap()
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
        onboarding.hubBack()

        // Close the hub — the walk configured three seats by hand.
        onboarding.hubDone.tap()
        onboarding.continueFrom("services")

        // Step 4 — Reports & safety (3 of 3). Directory has the UITest
        // Authority, so the step is MANDATORY: Continue stays disabled
        // and Skip never appears until a mandate is signed.
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

        // Step 5 — Recovery phrase. Unnumbered; the deferral reads
        // "Remind me later" (the only skippable step). The primary
        // ("I've written it down") is OUTCOME-GATED: disabled until
        // the phrase was actually revealed. Walk the reveal through
        // the real backup sheet (mock biometric), then advance — the
        // verify quiz has its own coverage in OnymRecovery.
        XCTAssertTrue(onboarding.title("recoveryPhrase").waitForExistence(timeout: 5))
        XCTAssertTrue(onboarding.recoveryStatus.waitForExistence(timeout: 5),
                      "recovery status card never appeared")
        XCTAssertTrue(onboarding.skip("recoveryPhrase").exists,
                      "recovery phrase must offer the Remind-me-later deferral")
        let recoveryPrimary = onboarding.primary("recoveryPhrase")
        XCTAssertTrue(recoveryPrimary.waitForExistence(timeout: 5))
        XCTAssertFalse(recoveryPrimary.isEnabled,
                       "\"I've written it down\" must stay disabled before the reveal")
        onboarding.recoveryReveal.tap()
        let introContinue = app.buttons["intro.continue_button"]
        XCTAssertTrue(introContinue.waitForExistence(timeout: 5),
                      "backup intro never appeared")
        XCTAssertTrue(waitUntilEnabled(introContinue, timeout: 5),
                      "backup intro Continue never became ready")
        introContinue.tap()
        let revealTap = app.buttons["reveal.tap_button"]
        XCTAssertTrue(revealTap.waitForExistence(timeout: 10),
                      "reveal screen never appeared (mock biometric should auto-pass)")
        revealTap.tap()
        XCTAssertTrue(app.staticTexts["reveal.word.1"].waitForExistence(timeout: 5),
                      "revealed words never appeared")
        // Close the sheet without the quiz — the reveal alone is what
        // unlocks the step's primary.
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitUntilEnabled(recoveryPrimary, timeout: 5),
                      "primary should be enabled after the reveal")
        onboarding.continueFrom("recoveryPhrase")

        // Step 6 — Done. Summary card renders; "Start messaging"
        // completes and the cover dismisses onto the Chats tab.
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
