import XCTest

/// Focused UI coverage of the Search tab: send a few messages into a
/// group, then search their text and open a result — asserting the
/// matched message opens in its chat thread.
///
/// Single-identity: the app bootstraps one identity on `--reset-keychain`
/// (see `OnymIOSApp.bootstrap`), so no identity add/switch dance is
/// needed. The group is created with real Poseidon proof against the
/// in-memory ledger (`--ui-loopback`); sending to a group of one member
/// persists locally as `.sent`, which is all search reads.
final class SearchUITests: XCTestCase {

    private let baseArgs = [
        "--ui-testing", "--mock-biometric", "--ui-loopback",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_search_findsMessage_andOpensChatAtIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-keychain"] + baseArgs
        app.launch()

        // Create a group with the bootstrap identity.
        let create = CreateGroupScreen(app: app)
        create.open()
        create.typeName("Notes")
        create.tapNext()
        create.tapCreate()
        XCTAssertTrue(create.waitForSuccess(),
                      "group creation never reached the success screen")
        create.tapShareInvite()
        let share = ShareInviteScreen(app: app)
        XCTAssertTrue(share.waitReady(), "share-invite screen never appeared")
        share.done()

        // Open the group and send a few messages to search over.
        openChat(app)
        let thread = ChatThreadScreen(app: app)
        XCTAssertTrue(thread.waitReady(), "chat thread never opened")
        thread.send("meeting at noon")
        thread.send("lunch plans today")
        thread.send("dinner tonight")
        XCTAssertTrue(thread.waitForMessage("dinner tonight"),
                      "sent messages never rendered in the thread")
        thread.back()

        // Search for one of them.
        let search = SearchScreen(app: app)
        search.tapSearchTab()
        search.search(for: "lunch")
        let hit = search.result(containing: "lunch plans today")
        XCTAssertTrue(hit.waitForExistence(timeout: 10),
                      "search result for 'lunch' never appeared")

        // Tapping the result opens the thread with the matched message.
        hit.tap()
        XCTAssertTrue(app.textViews["chat.input.textview"].waitForExistence(timeout: 15),
                      "tapping a search result never opened the chat thread")
        XCTAssertTrue(app.staticTexts["lunch plans today"].waitForExistence(timeout: 15),
                      "the searched message wasn't shown in the opened thread")
    }

    func test_search_noMatches_showsNoResults() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-keychain"] + baseArgs
        app.launch()

        let create = CreateGroupScreen(app: app)
        create.open()
        create.typeName("Notes")
        create.tapNext()
        create.tapCreate()
        XCTAssertTrue(create.waitForSuccess(),
                      "group creation never reached the success screen")
        create.tapShareInvite()
        let share = ShareInviteScreen(app: app)
        XCTAssertTrue(share.waitReady(), "share-invite screen never appeared")
        share.done()

        openChat(app)
        let thread = ChatThreadScreen(app: app)
        XCTAssertTrue(thread.waitReady(), "chat thread never opened")
        thread.send("hello world")
        XCTAssertTrue(thread.waitForMessage("hello world"),
                      "sent message never rendered")
        thread.back()

        let search = SearchScreen(app: app)
        search.tapSearchTab()
        search.search(for: "zqxjnonsense")
        // No result row should ever appear for a non-matching query.
        let anyResult = app.staticTexts["hello world"]
        XCTAssertFalse(anyResult.waitForExistence(timeout: 5),
                       "a non-matching query must surface no results")
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
