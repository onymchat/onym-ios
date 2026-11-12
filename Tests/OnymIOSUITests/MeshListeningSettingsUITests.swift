import XCTest

/// "Listen over Bluetooth" must be reachable from Settings. It once lived
/// on a screen nothing navigated to, which left the whole Bluetooth
/// listener impossible to turn on — this pins it to the Settings tab, and
/// pins that it survives the relaunch it needs (the scanner starts at
/// launch) — and that it applies live: turning it on starts the listener
/// at once, with no relaunch.
final class MeshListeningSettingsUITests: XCTestCase {
    private func launch(resetKeychain: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--skip-onboarding", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (resetKeychain ? ["--reset-keychain"] : [])
        app.launch()
        return app
    }

    /// Scroll Settings until the switch is on screen.
    private func meshSwitch(in app: XCUIApplication) -> XCUIElement {
        let settings = SettingsScreen(app: app)
        XCTAssertTrue(settings.settingsTab.waitForExistence(timeout: 15), "Settings tab never appeared")
        settings.settingsTab.tap()
        let toggle = app.switches["settings.mesh_listening_toggle"]
        var swipes = 0
        while !(toggle.exists && toggle.isHittable), swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(toggle.exists && toggle.isHittable, "Listen over Bluetooth isn't reachable in Settings")
        return toggle
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    /// The switch is a labels-hidden SwiftUI Toggle; tap its knob side.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    func test_listenOverBluetooth_isReachableFromSettings_andSticksAcrossRelaunch() {
        // Answer the Bluetooth prompt the relaunch may raise.
        addUIInterruptionMonitor(withDescription: "Bluetooth permission") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        var app = launch(resetKeychain: true)
        var toggle = meshSwitch(in: app)
        if isOn(toggle) { flip(toggle) }
        XCTAssertFalse(isOn(toggle), "listening is off by default")

        flip(toggle)
        XCTAssertTrue(isOn(toggle), "the switch turns listening on")

        // Applied live: no relaunch — the listener starts now and the
        // status line under the switch says what the radio is doing.
        let status = app.descendants(matching: .any)["settings.mesh_status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no listener status after turning the switch on")
        let started = NSPredicate(format: "NOT (label CONTAINS 'Starting')")
        let reported = expectation(for: started, evaluatedWith: status)
        wait(for: [reported], timeout: 10)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "settings-nearby"
        shot.lifetime = .keepAlways
        add(shot)

        // Listening starts at launch: relaunch, and the setting holds.
        app.terminate()
        app = launch(resetKeychain: false)
        toggle = meshSwitch(in: app)
        XCTAssertTrue(isOn(toggle), "listening stays on across a relaunch")

        // Leave the simulator as we found it.
        flip(toggle)
        XCTAssertFalse(isOn(toggle))
    }
}
