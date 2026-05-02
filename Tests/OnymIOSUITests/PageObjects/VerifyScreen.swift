import XCTest

/// Page object for the recovery-flow Verify screen.
///
/// The flow generates 3 random rounds, each asking for a specific 1-based
/// position and rendering 4 candidate words (1 correct + 3 distractors).
/// The current position is exposed via the `verify.position` static text;
/// each option button's identifier embeds the displayed word
/// (`verify.option.<word>`).
struct VerifyScreen {
    let app: XCUIApplication

    var positionLabel: XCUIElement { app.staticTexts["verify.position"] }
    var errorMessage: XCUIElement  { app.staticTexts["verify.error_message"] }

    /// Returns the 1-based word position the current round is asking for.
    /// Waits for the round's UI to settle.
    func waitForRound(timeout: TimeInterval = 5) -> Int {
        XCTAssertTrue(positionLabel.waitForExistence(timeout: timeout),
                      "verify position label never appeared")
        guard let position = Int(positionLabel.label) else {
            XCTFail("verify.position label is not an integer: \(positionLabel.label)")
            return 0
        }
        return position
    }

    /// Returns true if a verify option button for `word` is currently visible.
    func hasOption(_ word: String) -> Bool {
        app.buttons["verify.option.\(word)"].exists
    }

    /// Picks the option labeled `word`. Asserts the option exists.
    func pick(word: String) {
        let option = app.buttons["verify.option.\(word)"]
        XCTAssertTrue(option.waitForExistence(timeout: 2),
                      "no verify option for word `\(word)`")
        option.tap()
    }

    /// Picks any visible option whose word is **not** `correctWord`.
    /// Used by the wrong-pick test, which doesn't care which wrong option
    /// gets chosen — just that one of them is.
    func pickAnyWrongOption(correctWord: String) {
        let allOptions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'verify.option.'")
        )
        let count = allOptions.count
        XCTAssertGreaterThan(count, 0, "no verify option buttons visible")
        for i in 0..<count {
            let option = allOptions.element(boundBy: i)
            let id = option.identifier
            if id != "verify.option.\(correctWord)" {
                option.tap()
                return
            }
        }
        XCTFail("every visible option matched the correct word `\(correctWord)`")
    }
}
