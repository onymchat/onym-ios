import XCTest

/// Page object for the recovery-flow Done screen.
struct DoneScreen {
    let app: XCUIApplication

    var title: XCUIElement      { app.staticTexts["done.title"] }
    var doneButton: XCUIElement { app.buttons["done.button"] }

    func waitForDisplayed(timeout: TimeInterval = 5) -> Bool {
        title.waitForExistence(timeout: timeout)
    }

    func tapDone() {
        XCTAssertTrue(doneButton.isHittable, "done button not hittable")
        doneButton.tap()
    }
}
