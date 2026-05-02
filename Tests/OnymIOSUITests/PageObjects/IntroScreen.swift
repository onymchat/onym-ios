import XCTest

/// Page object for the recovery-flow Intro screen.
struct IntroScreen {
    let app: XCUIApplication

    var continueButton: XCUIElement {
        app.buttons["intro.continue_button"]
    }

    /// Waits for the Continue button to exist AND become hittable. The
    /// button is rendered immediately but disabled until the
    /// `IdentityRepository.bootstrap()` call inside the flow's `start()`
    /// resolves and hands `flow.isReady = true` back to the view.
    func waitForReady(timeout: TimeInterval = 8) -> Bool {
        guard continueButton.waitForExistence(timeout: timeout) else { return false }
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: continueButton)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func tapContinue() {
        XCTAssertTrue(waitForReady(), "intro continue button never became hittable")
        continueButton.tap()
    }
}
