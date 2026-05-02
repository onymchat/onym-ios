import XCTest

/// Page object for the recovery-flow Reveal screen.
///
/// Each of the 12 phrase words has its own accessibility identifier
/// (`reveal.word.<1-based-position>`) so the UI test can reconstruct the
/// full mnemonic after tapping reveal — and then look up which word lives
/// at each position when verifying.
struct RevealScreen {
    let app: XCUIApplication

    var tapToRevealButton: XCUIElement { app.buttons["reveal.tap_button"] }
    var continueButton: XCUIElement   { app.buttons["reveal.continue_button"] }
    var copyButton: XCUIElement       { app.buttons["reveal.copy_button"] }

    func waitForUnrevealed(timeout: TimeInterval = 5) -> Bool {
        tapToRevealButton.waitForExistence(timeout: timeout)
    }

    func tapReveal() {
        XCTAssertTrue(waitForUnrevealed(), "reveal screen never showed `Tap to reveal`")
        tapToRevealButton.tap()
    }

    /// Reads positions 1…12 off the Reveal grid. Call only after `tapReveal()`.
    func capturedPhrase() -> [String] {
        var words: [String] = []
        for position in 1...12 {
            let element = app.staticTexts["reveal.word.\(position)"]
            XCTAssertTrue(element.waitForExistence(timeout: 2),
                          "reveal.word.\(position) never appeared")
            words.append(element.label)
        }
        return words
    }

    func tapContinue() {
        XCTAssertTrue(continueButton.isHittable,
                      "reveal continue button not hittable (did you forget to tap reveal first?)")
        continueButton.tap()
    }
}
