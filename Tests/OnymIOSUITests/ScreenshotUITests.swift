import XCTest

/// App Store screenshot generator, driven by `fastlane snapshot`
/// (`bundle exec fastlane screenshots`). Uses the offline `--ui-loopback`
/// harness so it runs deterministically with no network, seeds a group +
/// a short conversation, and captures the key screens in every language
/// the Snapfile lists.
///
/// All seeded content (group name, invitation, messages) is user text,
/// identical across locales, so the waits below are language-independent.
/// The Settings/identity shot is captured last, after group creation has
/// exercised the bootstrapped identity, so it's fully loaded by then.
final class ScreenshotUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func test_generateScreenshots() {
        let app = XCUIApplication()
        setupSnapshot(app)
        // Offline, deterministic harness. Language/locale is controlled by
        // snapshot (Snapfile `languages`) — deliberately not set here.
        app.launchArguments += [
            "--ui-testing", "--reset-keychain", "--mock-biometric", "--ui-loopback",
        ]
        app.launch()

        let settings = SettingsScreen(app: app)
        let chats = ChatsScreen(app: app)
        let create = CreateGroupScreen(app: app)
        let thread = ChatThreadScreen(app: app)

        // 1 — Create Group (name + invitation message).
        chats.tapChatsTab()
        create.open()
        create.typeName("Weekend Trip")
        create.typeInvitation(
            "House rules: be kind, share the good photos, no spoilers. Glad you're here \u{2014} let's plan the weekend."
        )
        snapshot("02_create_group")

        // Finish creating; return to the Chats list.
        create.tapNext()
        create.tapCreate()
        XCTAssertTrue(create.waitForSuccess(), "group creation never reached success")
        create.tapDone()

        // 2 — Chats list with the new group.
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Weekend Trip'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "new chat never appeared in the list")
        snapshot("03_chats")

        // 3 — Chat welcome: the rich empty state (invitation + privacy points).
        row.tap()
        XCTAssertTrue(thread.waitReady(), "chat thread never opened")
        // The invitation is user text (same in every locale) — wait on it.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'House rules'"))
                .firstMatch.waitForExistence(timeout: 8),
            "welcome/empty state never rendered the invitation"
        )
        snapshot("04_welcome")

        // 4 — A conversation.
        thread.send("Landing at 4 \u{2014} who's grabbing the keys?")
        _ = thread.waitForMessage("Landing at 4 \u{2014} who's grabbing the keys?")
        thread.send("Got them \u{1F511} see you at the cabin")
        _ = thread.waitForMessage("Got them \u{1F511} see you at the cabin")
        snapshot("05_chat")

        // Leave the thread — the tab bar is hidden inside a chat, so pop
        // back to the Chats list before switching tabs.
        thread.back()

        // 5 — Identity & invite QR (Settings). Captured last: by now the
        // bootstrapped identity is fully loaded (group creation used it).
        // The per-identity rename affordance is a stable, language-
        // independent signal that the carousel page has rendered.
        settings.tapSettingsTab()
        let identityRendered = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'identity.rename.'")
        ).firstMatch
        XCTAssertTrue(identityRendered.waitForExistence(timeout: 20),
                      "identity carousel never appeared")
        snapshot("01_identity")
    }
}
