import XCTest

/// End-to-end UI coverage of two identities on ONE device exchanging
/// chat messages through a real Founder (Tyranny) group, including
/// read receipts in both directions.
///
/// ## Offline harness (`--ui-loopback`)
///
/// The production build talks to real Nostr relays + the SEP contract
/// relayer. Those can't run in CI, so `--ui-loopback` swaps in:
///   - `UITestLoopbackInboxTransport` — in-process, store-and-forward
///     inbox routing so the two identities' inboxes exchange
///     invitations / messages / receipts with no network.
///   - `UITestChainLedger` + `UITestSEPContractTransport` — an
///     in-memory stand-in for on-chain state, fed by both the
///     `create_group` / `update_commitment` writes and the
///     `get_commitment` reads, so the Tyranny group anchors and then
///     verifies against the exact same commitment. The Poseidon proof
///     itself stays real FFI — only the relayer round-trip is faked.
///
/// The one deeplink hop (identity 2 opening identity 1's invite link)
/// is delivered by relaunching with `--open-url <link>` rather than
/// driving Safari — far more deterministic for CI, and it still goes
/// through the app's real `.onOpenURL`/`DeeplinkCapture` path. The
/// invite link is genuinely read back from the system pasteboard after
/// the "Copy invite link" tap. Everything after the relaunch (join →
/// approve → messages → receipts) runs in one continuous session.
final class MultiIdentityChatUITests: XCTestCase {

    /// Args common to both launches. Session 1 additionally passes
    /// `--reset-keychain`; session 2 must NOT (it relies on the
    /// identities, group, and encryption key persisting).
    private let baseArgs = [
        "--ui-testing", "--mock-biometric", "--ui-loopback",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_founderGroup_twoIdentities_messageRoundTrip_withReadReceipts() throws {
        let app = XCUIApplication()

        // ───────── Session 1: identities + group + invite link ─────────
        app.launchArguments = ["--reset-keychain"] + baseArgs
        app.launch()

        addIdentity(app, name: "Alice")
        addIdentity(app, name: "Bob")

        // Identity 1 (Alice) creates a Founder group.
        switchIdentity(app, to: "Alice")
        let create = CreateGroupScreen(app: app)
        create.open()
        create.typeName("Founders")
        create.tapNext()
        create.tapCreate()
        XCTAssertTrue(create.waitForSuccess(),
                      "Founder group creation never reached the success screen")

        // Share the invite and read the link off the pasteboard.
        create.tapShareInvite()
        let share = ShareInviteScreen(app: app)
        XCTAssertTrue(share.waitReady(), "share-invite screen never appeared")
        guard let inviteLink = share.readInviteLink(), !inviteLink.isEmpty else {
            return XCTFail("invite link was not exposed by the share-invite screen")
        }
        share.done()

        // Leave Bob active so session 2 boots as the joiner.
        switchIdentity(app, to: "Bob")
        app.terminate()

        // ───────── Session 2: join → approve → chat ─────────
        app.launchArguments = baseArgs + ["--open-url", inviteLink]
        app.launch()

        // Identity 2 (Bob) accepts the invitation (deeplink → Join).
        let join = JoinScreen(app: app)
        XCTAssertTrue(join.waitReady(),
                      "Join sheet never appeared from the --open-url deeplink")
        join.typeLabel("Bob")
        join.send()
        join.dismissAfterSend()

        // Identity 1 (Alice) approves the join request.
        switchIdentity(app, to: "Alice")
        let approve = ApproveRequestsScreen(app: app)
        approve.open()
        approve.approveFirst()
        XCTAssertTrue(approve.waitForSuccess(),
                      "join approval (update_commitment) never succeeded")
        approve.close()

        // ───────── Bob → Alice: message received + read ─────────
        switchIdentity(app, to: "Bob")
        openChat(app)
        let thread = ChatThreadScreen(app: app)
        XCTAssertTrue(thread.waitReady(), "Bob's chat thread never opened")
        thread.send("Hello from Bob")
        XCTAssertTrue(thread.waitForMessage("Hello from Bob"),
                      "Bob's own outgoing message never rendered")
        thread.back()

        // Alice asserts she received it; viewing ships a read receipt.
        switchIdentity(app, to: "Alice")
        openChat(app)
        XCTAssertTrue(thread.waitReady(), "Alice's chat thread never opened")
        XCTAssertTrue(thread.waitForMessage("Hello from Bob"),
                      "Alice never received Bob's message")
        thread.back()

        // Bob asserts his message was read.
        switchIdentity(app, to: "Bob")
        openChat(app)
        XCTAssertTrue(thread.waitForStatus("Read"),
                      "Bob's message never flipped to Read after Alice opened the thread")
        thread.back()

        // ───────── Alice → Bob: same, other direction ─────────
        switchIdentity(app, to: "Alice")
        openChat(app)
        thread.send("Hello from Alice")
        XCTAssertTrue(thread.waitForMessage("Hello from Alice"),
                      "Alice's own outgoing message never rendered")
        thread.back()

        switchIdentity(app, to: "Bob")
        openChat(app)
        XCTAssertTrue(thread.waitForMessage("Hello from Alice"),
                      "Bob never received Alice's message")
        thread.back()

        switchIdentity(app, to: "Alice")
        openChat(app)
        XCTAssertTrue(thread.waitForStatus("Read"),
                      "Alice's message never flipped to Read after Bob opened the thread")
        thread.back()

        // ───────── Bob → Alice: image message ─────────
        // Under `--ui-loopback` the attach button sends a generated test
        // image (the system photo picker can't be driven from XCUITest);
        // the blob round-trips through the in-memory Blossom fake.
        switchIdentity(app, to: "Bob")
        openChat(app)
        XCTAssertTrue(thread.waitReady(), "Bob's chat thread never opened")
        // Two-step: attach stages the image in the preview strip, then
        // Send confirms.
        app.buttons["chat.input.attach"].tap()
        XCTAssertTrue(app.buttons["chat.input.media_strip.remove"].firstMatch.waitForExistence(timeout: 10),
                      "attaching an image never staged it in the preview strip")
        app.buttons["chat.input.send"].tap()
        XCTAssertTrue(app.images["chat.bubble.image"].waitForExistence(timeout: 25),
                      "Bob's sent image bubble never rendered")

        // Tap the image → full-screen viewer opens; swipe down → it
        // dismisses (the viewer is dismissed by swipe, not tap).
        app.images["chat.bubble.image"].tap()
        let fullscreen = app.images["chat.image.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 10),
                      "tapping the image never opened the full-screen viewer")
        fullscreen.swipeDown(velocity: .fast)
        XCTAssertTrue(waitForDisappearance(of: fullscreen, timeout: 10),
                      "swiping down never dismissed the full-screen image viewer")
        thread.back()

        switchIdentity(app, to: "Alice")
        openChat(app)
        XCTAssertTrue(app.images["chat.bubble.image"].waitForExistence(timeout: 25),
                      "Alice never received + rendered the image")
        thread.back()

        // ───────── Alice → Bob: video message ─────────
        // Under `--ui-loopback` the attach-video button sends a canned
        // video (PHPicker + AVFoundation transcoding can't run from
        // XCUITest); both the poster and video blobs round-trip through
        // the in-memory Blossom fake. The bubble exposes the poster as
        // `chat.bubble.video`.
        switchIdentity(app, to: "Alice")
        openChat(app)
        XCTAssertTrue(thread.waitReady(), "Alice's chat thread never opened")
        // Two-step: attach stages the video, then Send confirms.
        app.buttons["chat.input.attach_video"].tap()
        XCTAssertTrue(app.buttons["chat.input.media_strip.remove"].firstMatch.waitForExistence(timeout: 10),
                      "attaching a video never staged it in the preview strip")
        app.buttons["chat.input.send"].tap()
        XCTAssertTrue(app.images["chat.bubble.video"].waitForExistence(timeout: 25),
                      "Alice's sent video bubble never rendered")

        // Tap the video → full-screen player opens; swipe down → it
        // dismisses (there's no close button; swipe is the only dismiss).
        app.images["chat.bubble.video"].tap()
        let videoPlayer = app.descendants(matching: .any)["chat.video.fullscreen"]
        XCTAssertTrue(videoPlayer.waitForExistence(timeout: 10),
                      "tapping the video never opened the full-screen player")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitForDisappearance(of: videoPlayer, timeout: 10),
                      "swiping down never dismissed the full-screen video player")
        thread.back()

        switchIdentity(app, to: "Bob")
        openChat(app)
        XCTAssertTrue(app.images["chat.bubble.video"].waitForExistence(timeout: 25),
                      "Bob never received + rendered the video")
        thread.back()

        // ───────── Album: two images → one grid message ─────────
        // Stage two images in the preview strip, then Send once → a
        // single album bubble rendered as a grid.
        switchIdentity(app, to: "Bob")
        openChat(app)
        XCTAssertTrue(thread.waitReady(), "Bob's chat thread never opened for album")
        app.buttons["chat.input.attach"].tap()
        app.buttons["chat.input.attach"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "chat.input.media_strip.remove").element(boundBy: 1).waitForExistence(timeout: 10),
                      "the preview strip never staged two items for the album")
        app.buttons["chat.input.send"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["chat.bubble.album.tile"].firstMatch
                .waitForExistence(timeout: 25),
            "the album grid never rendered"
        )
        thread.back()

        // ───────── Search: find a message + open its chat ─────────
        // As Alice, search her messages for Bob's text, tap the result,
        // and assert it opens the chat thread scrolled to that message.
        switchIdentity(app, to: "Alice")
        let search = SearchScreen(app: app)
        search.tapSearchTab()
        search.search(for: "Hello from Bob")
        let hit = search.result(containing: "Hello from Bob")
        XCTAssertTrue(hit.waitForExistence(timeout: 10),
                      "search result for 'Hello from Bob' never appeared")
        hit.tap()
        // Tapping the result opens the thread (composer present) with the
        // matched message rendered — proving search → open-at-message.
        XCTAssertTrue(app.textViews["chat.input.textview"].waitForExistence(timeout: 15),
                      "tapping a search result never opened the chat thread")
        XCTAssertTrue(app.staticTexts["Hello from Bob"].waitForExistence(timeout: 15),
                      "the searched message wasn't shown in the opened thread")
    }

    // MARK: - Helpers

    private func addIdentity(_ app: XCUIApplication, name: String) {
        let settings = SettingsScreen(app: app)
        settings.tapSettingsTab()
        settings.tapIdentities()
        let identities = IdentitiesScreen(app: app)
        _ = identities.waitForReady()
        identities.tapAdd()
        identities.typeAddName(name)
        identities.tapAddSubmit()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8),
                      "newly-added identity '\(name)' never appeared")
    }

    /// Switch the active identity via the Chats toolbar picker, matching
    /// the menu row by its visible name (we don't know the UUIDs here).
    private func switchIdentity(_ app: XCUIApplication, to name: String) {
        let chats = ChatsScreen(app: app)
        chats.tapChatsTab()
        chats.tapPicker()
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "identity '\(name)' never appeared in the picker menu")
        item.tap()
        _ = chats.navTitle(name).waitForExistence(timeout: 5)
    }

    /// Poll until `element` no longer exists, or the timeout elapses.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(100_000)
        }
        return !element.exists
    }

    /// Open the single group's thread from the Chats list.
    private func openChat(_ app: XCUIApplication) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'chats.row.'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 25),
                      "chat row never appeared in the list")
        row.tap()
    }
}
