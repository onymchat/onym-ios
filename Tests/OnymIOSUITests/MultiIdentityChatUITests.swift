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

        TwoIdentityFlow.addIdentity(app, name: "Alice")
        TwoIdentityFlow.addIdentity(app, name: "Bob")

        // Identity 1 (Alice) creates a Founder group.
        TwoIdentityFlow.switchIdentity(app, to: "Alice")
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
        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        app.terminate()

        // ───────── Session 2: join → approve → chat ─────────
        app.launchArguments = baseArgs + ["--open-url", inviteLink]
        app.launch()

        // Identity 2 (Bob) joins from the deeplink. The link opens a
        // confirmation screen — delivery is not consent, since anything
        // on the device can open the app's URL types — and the request
        // goes out only on Send, under the name typed there.
        let confirm = JoinConfirmScreen(app: app)
        XCTAssertTrue(confirm.waitReady(),
                      "join confirmation never appeared from the --open-url deeplink")
        // Joining is one tap: the name field arrives holding the active
        // identity's own alias, so nobody has to type their own name to
        // get into a chat. Asserting it here is what keeps that true —
        // the cold-start link is exactly the moment the identity cache
        // is unread, and an empty field would make Send unavailable.
        XCTAssertEqual(confirm.prefilledName, "Bob",
                       "the confirmation must arrive pre-filled with the identity's name")
        confirm.send()

        let pending = PendingChatScreen(app: app)
        XCTAssertTrue(pending.waitReady(),
                      "pending chat never appeared after confirming the join")
        pending.back()

        // Identity 1 (Alice) approves the join request — from inside the
        // group's chat thread, which is the whole point of the surface:
        // there is no separate "Join requests" screen to find.
        TwoIdentityFlow.switchIdentity(app, to: "Alice")
        TwoIdentityFlow.openChat(app)
        let thread = ChatThreadScreen(app: app)
        XCTAssertTrue(thread.waitReady(), "Alice's chat thread never opened")
        let joinRequest = JoinRequestRow(app: app)
        joinRequest.acceptFirst()
        XCTAssertTrue(joinRequest.waitForJoinedNotice(alias: "Bob"),
                      "join approval (update_commitment) never produced a joined notice")
        thread.back()

        // ───────── Bob → Alice: message received + read ─────────
        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(thread.waitReady(), "Bob's chat thread never opened")
        thread.send("Hello from Bob")
        XCTAssertTrue(thread.waitForMessage("Hello from Bob"),
                      "Bob's own outgoing message never rendered")
        thread.back()

        // Alice asserts she received it; viewing ships a read receipt.
        TwoIdentityFlow.switchIdentity(app, to: "Alice")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(thread.waitReady(), "Alice's chat thread never opened")
        XCTAssertTrue(thread.waitForMessage("Hello from Bob"),
                      "Alice never received Bob's message")
        thread.back()

        // Bob asserts his message was read.
        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(thread.waitForStatus("Read"),
                      "Bob's message never flipped to Read after Alice opened the thread")
        thread.back()

        // ───────── Alice → Bob: same, other direction ─────────
        TwoIdentityFlow.switchIdentity(app, to: "Alice")
        TwoIdentityFlow.openChat(app)
        thread.send("Hello from Alice")
        XCTAssertTrue(thread.waitForMessage("Hello from Alice"),
                      "Alice's own outgoing message never rendered")
        thread.back()

        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(thread.waitForMessage("Hello from Alice"),
                      "Bob never received Alice's message")
        thread.back()

        TwoIdentityFlow.switchIdentity(app, to: "Alice")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(thread.waitForStatus("Read"),
                      "Alice's message never flipped to Read after Bob opened the thread")
        thread.back()

        // ───────── Bob → Alice: image message ─────────
        // Under `--ui-loopback` the attach button sends a generated test
        // image (the system photo picker can't be driven from XCUITest);
        // the blob round-trips through the in-memory Blossom fake.
        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        TwoIdentityFlow.openChat(app)
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

        TwoIdentityFlow.switchIdentity(app, to: "Alice")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(app.images["chat.bubble.image"].waitForExistence(timeout: 25),
                      "Alice never received + rendered the image")
        thread.back()

        // ───────── Alice → Bob: voice message ─────────
        // Under `--ui-loopback` a plain tap on the mic button sends a
        // canned voice clip (a real press-and-hold recording can't be
        // driven from XCUITest); the audio blob round-trips through the
        // in-memory Blossom fake. The bubble exposes the player button as
        // `chat.bubble.voice.play`.
        TwoIdentityFlow.switchIdentity(app, to: "Alice")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(thread.waitReady(), "Alice's chat thread never opened")
        // The mic button is shown when the composer is empty.
        app.buttons["chat.input.mic"].tap()
        XCTAssertTrue(app.buttons["chat.bubble.voice.play"].waitForExistence(timeout: 25),
                      "Alice's sent voice bubble never rendered")
        thread.back()

        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(app.buttons["chat.bubble.voice.play"].waitForExistence(timeout: 25),
                      "Bob never received + rendered the voice message")
        thread.back()

        // ───────── Album: two images → one grid message ─────────
        // Stage two images in the preview strip, then Send once → a
        // single album bubble rendered as a grid.
        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        TwoIdentityFlow.openChat(app)
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
        TwoIdentityFlow.switchIdentity(app, to: "Alice")
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
        XCTAssertTrue(ChatThreadScreen(app: app).waitForMessage("Hello from Bob", timeout: 15),
                      "the searched message wasn't shown in the opened thread")
    }

    // MARK: - Helpers

    /// Poll until `element` no longer exists, or the timeout elapses.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(100_000)
        }
        return !element.exists
    }

}
