import XCTest

/// Page object for the first-launch onboarding cover. Only meaningful
/// when the app was launched with `--ui-onboarding` (the onboarding
/// tests build their own argument lists; `AppLauncher.launchFresh`
/// always passes `--skip-onboarding`) — without it the cover never
/// presents.
///
/// Accessibility identifiers follow the scaffold's convention:
/// `onboarding.<step>.<element>` — `title` / `primary` / `skip` /
/// `back` from `OnboardingStepScaffold`, step-specific elements from
/// the app-layer step bodies (`OnboardingSteps.swift`).
struct OnboardingScreen {
    let app: XCUIApplication

    // MARK: - Scaffold chrome

    func title(_ step: String) -> XCUIElement {
        app.staticTexts["onboarding.\(step).title"]
    }

    func primary(_ step: String) -> XCUIElement {
        app.buttons["onboarding.\(step).primary"]
    }

    func skip(_ step: String) -> XCUIElement {
        app.buttons["onboarding.\(step).skip"]
    }

    /// Wait for a step's title, then tap its primary button — the
    /// generic "Continue" walk move. Fails with the hierarchy dump so
    /// a wrong step or a missing surface is diagnosable from CI logs.
    func continueFrom(_ step: String, timeout: TimeInterval = 5) {
        XCTAssertTrue(title(step).waitForExistence(timeout: timeout),
                      "onboarding step \(step) never appeared. Hierarchy:\n\(app.debugDescription)")
        let button = primary(step)
        XCTAssertTrue(button.waitForExistence(timeout: timeout),
                      "onboarding \(step) primary button never appeared")
        XCTAssertTrue(button.isEnabled,
                      "onboarding \(step) primary button should be enabled")
        button.tap()
    }

    // MARK: - Discovery confirm step

    /// "Verify & Confirm" on the seeded (unpinned) default source.
    var discoveryConfirmButton: XCUIElement {
        app.buttons["onboarding.discoveryConfirm.confirm"]
    }

    /// The TOFU fingerprint hero.
    var discoveryFingerprint: XCUIElement {
        app.staticTexts["onboarding.discoveryConfirm.fingerprint"]
    }

    /// "Pin Key & Confirm".
    var discoveryPinButton: XCUIElement {
        app.buttons["onboarding.discoveryConfirm.pin"]
    }

    /// The "Provider confirmed" state. The identifier sits on a
    /// SwiftUI `VStack` whose element type varies by iOS version —
    /// match any descendant (same pattern as
    /// `DiscoverySettingsScreen.addDone`).
    var discoveryAdded: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "onboarding.discoveryConfirm.added")
            .firstMatch
    }

    // MARK: - Catalog rows (transport / blob / notary steps)

    /// A discovery-catalog row inside a step. `entryId` is the
    /// aggregate row id: `<providerId>|<catalogId>|<componentId>`.
    func catalogRow(step: String, entryId: String) -> XCUIElement {
        app.buttons["onboarding.\(step).catalog.\(entryId)"]
    }

    /// A configured-endpoint row inside a step.
    func configuredRow(step: String, url: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "onboarding.\(step).configured.\(url)")
            .firstMatch
    }

    // MARK: - Module consent sheet (shared with Settings)

    var consentAccept: XCUIElement {
        app.buttons["settings.module_consent.accept"]
    }

    var consentDone: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "settings.module_consent.done")
            .firstMatch
    }

    var consentDismiss: XCUIElement {
        app.buttons["settings.module_consent.dismiss"]
    }

    // MARK: - Notary step

    /// A published-list row (tap to add, no consent sheet).
    func notaryPublishedRow(url: String) -> XCUIElement {
        app.buttons["onboarding.notary.published.\(url)"]
    }

    // MARK: - Moderation step (shared consent surface)

    func moderationAuthorityRow(componentId: String) -> XCUIElement {
        app.buttons["moderation.consent.authority.\(componentId)"]
    }

    var moderationAgree: XCUIElement {
        app.buttons["moderation.consent.agree"]
    }

    /// "Mandate signed" — the consent surface's done state.
    var moderationDone: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "moderation.consent.done")
            .firstMatch
    }

    // MARK: - Done step

    var doneSummary: XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "onboarding.done.summary")
            .firstMatch
    }
}
