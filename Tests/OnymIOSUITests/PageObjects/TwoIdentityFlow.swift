import XCTest

/// The two-identity dance every multi-party UI test opens with.
///
/// This existed verbatim in `MultiIdentityChatUITests`, `SearchUITests`
/// and `GroupRulesProofUITests` before it was extracted — three copies
/// of the same waits, which is three places to fix when the picker or
/// the carousel moves.
enum TwoIdentityFlow {

    /// Create an identity from the settings carousel and wait for it to
    /// land. The carousel jumps to the new identity's QR page on
    /// create, so its alias surfaces as a static text.
    static func addIdentity(
        _ app: XCUIApplication,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        SettingsScreen(app: app).addIdentityViaCarousel(name: name)
        let alias = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", name)
        ).firstMatch
        XCTAssertTrue(
            alias.waitForExistence(timeout: 8),
            "newly-added identity '\(name)' never appeared in the carousel",
            file: file, line: line
        )
    }

    /// Switch the active identity via the Chats toolbar picker, matched
    /// by visible name — the UUIDs aren't known here.
    static func switchIdentity(
        _ app: XCUIApplication,
        to name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let chats = ChatsScreen(app: app)
        chats.tapChatsTab()
        chats.tapPicker()
        let item = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", name)
        ).firstMatch
        XCTAssertTrue(
            item.waitForExistence(timeout: 5),
            "identity '\(name)' never appeared in the picker menu",
            file: file, line: line
        )
        item.tap()
        _ = chats.navTitle(name).waitForExistence(timeout: 5)
    }

    /// Open the first chat in the list.
    static func openChat(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'chats.row.'")
        ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 25),
            "chat row never appeared in the list", file: file, line: line
        )
        row.tap()
    }
}
