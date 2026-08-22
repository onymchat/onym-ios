import XCTest

/// The rules, end to end: written at creation, read and signed on the
/// way in, and shown afterwards to everyone in the group.
///
/// The last part is why this is a UI test and not three unit tests. The
/// claim behind the feature is that a member's agreement is visible and
/// checkable by *any* member — not only by the founder who admitted
/// them — and that only holds if the signature survives the invitation
/// payload and the announcement. Nothing below the UI exercises that
/// whole path, so it is asserted here, from both devices.
final class GroupRulesProofUITests: XCTestCase {

    private let baseArgs = [
        "--ui-testing", "--mock-biometric", "--ui-loopback",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    private let rules = "Be kind. No links. Ask before adding anyone."

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_rulesAreSignedOnTheWayInAndShownToBothMembersAfter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-keychain"] + baseArgs
        app.launch()

        TwoIdentityFlow.addIdentity(app, name: "Alice")
        TwoIdentityFlow.addIdentity(app, name: "Bob")
        TwoIdentityFlow.switchIdentity(app, to: "Alice")

        let create = CreateGroupScreen(app: app)
        create.open()
        create.typeName("Founders")
        create.typeInvitation(rules)
        create.tapNext()
        create.tapCreate()
        XCTAssertTrue(create.waitForSuccess(), "group creation never succeeded")
        create.tapShareInvite()
        let share = ShareInviteScreen(app: app)
        XCTAssertTrue(share.waitReady(), "share-invite screen never appeared")
        guard let link = share.readInviteLink(), !link.isEmpty else {
            return XCTFail("invite link was not exposed")
        }
        share.done()
        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        app.terminate()

        // ───────── Bob reads the rules and agrees ─────────
        app.launchArguments = baseArgs + ["--open-url", link]
        app.launch()

        let confirm = JoinConfirmScreen(app: app)
        XCTAssertTrue(confirm.waitReady(), "join confirmation never appeared")
        XCTAssertTrue(
            app.staticTexts[rules].waitForExistence(timeout: 5),
            "the rules must be on screen before anyone is asked to agree to them"
        )
        // The gate. A group with rules costs one more tap than one
        // without, and this is that tap.
        XCTAssertFalse(
            app.buttons["join_confirm.send"].isEnabled,
            "Send must stay closed until the rules are agreed to"
        )
        // SwiftUI hangs the identifier on the container rather than the
        // switch; there is exactly one switch on this screen.
        let agree = app.switches.firstMatch
        XCTAssertTrue(agree.waitForExistence(timeout: 5), "agree toggle missing")
        agree.tap()
        XCTAssertTrue(app.buttons["join_confirm.send"].isEnabled, "agreeing must open Send")
        confirm.send()

        let pending = PendingChatScreen(app: app)
        XCTAssertTrue(pending.waitReady(), "pending chat never appeared")
        pending.back()

        // ───────── The founder admits them ─────────
        TwoIdentityFlow.switchIdentity(app, to: "Alice")
        TwoIdentityFlow.openChat(app)
        let thread = ChatThreadScreen(app: app)
        XCTAssertTrue(thread.waitReady(), "Alice's thread never opened")
        JoinRequestRow(app: app).acceptFirst()
        XCTAssertTrue(
            JoinRequestRow(app: app).waitForJoinedNotice(alias: "Bob"),
            "join approval never produced a joined notice"
        )

        try assertMembersScreenShowsStandings(app, from: "Alice")

        // ───────── And Bob sees the same, on his own device ─────────
        thread.back()
        TwoIdentityFlow.switchIdentity(app, to: "Bob")
        TwoIdentityFlow.openChat(app)
        XCTAssertTrue(thread.waitReady(), "Bob's thread never opened")
        try assertMembersScreenShowsStandings(app, from: "Bob")
    }

    /// The rules, and both members' standings, as rendered for whoever
    /// is currently signed in. Identical from either side — that is the
    /// assertion.
    private func assertMembersScreenShowsStandings(
        _ app: XCUIApplication,
        from viewer: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        app.buttons["chat.info"].tap()
        XCTAssertTrue(
            app.staticTexts["GROUP RULES"].waitForExistence(timeout: 15),
            "\(viewer) never saw the group rules section", file: file, line: line
        )
        XCTAssertTrue(
            app.staticTexts[rules].exists,
            "\(viewer) saw the section without the rules in it", file: file, line: line
        )
        XCTAssertTrue(
            app.staticTexts["Signed the group rules"].waitForExistence(timeout: 10),
            "\(viewer) could not see that Bob signed", file: file, line: line
        )
        XCTAssertTrue(
            app.staticTexts["Wrote the group rules"].exists,
            "\(viewer) saw the founder marked as something other than the author",
            file: file, line: line
        )

        // And the proof behind the mark, with the wording it covers.
        // `XCTUnwrap`, not `?.tap()`: a silent no-op here surfaced as
        // "could not open Bob's proof", pointing at the sheet rather
        // than at the row that was never there.
        let bobRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'members.row.'")
        ).allElementsBoundByIndex.first { $0.label.contains("Bob") }
        try XCTUnwrap(bobRow, "\(viewer) saw no row for Bob").tap()
        XCTAssertTrue(
            app.staticTexts["WHAT THEY SIGNED"].waitForExistence(timeout: 5),
            "\(viewer) could not open Bob's proof", file: file, line: line
        )
        XCTAssertTrue(
            app.buttons["rules_proof.export"].exists,
            "\(viewer) had no way to export it", file: file, line: line
        )
        XCTAssertTrue(
            app.staticTexts["member"].exists,
            "\(viewer) saw a proof identified only by a self-asserted alias",
            file: file, line: line
        )
        app.buttons["rules_proof.done"].tap()

        // The other sheet on this screen. Both present through one
        // `sheet(item:)` over an enum now, because two `.sheet`
        // modifiers on one view leave SwiftUI honouring whichever it
        // likes — and this is the one that would have gone quiet, since
        // only the admin reaches it.
        let shareInvite = app.buttons["members.share_invite_button"]
        if shareInvite.waitForExistence(timeout: 2) {
            shareInvite.tap()
            let share = ShareInviteScreen(app: app)
            XCTAssertTrue(
                share.waitReady(),
                "\(viewer) is this group's admin and the share-invite sheet never presented",
                file: file, line: line
            )
            share.done()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
}
