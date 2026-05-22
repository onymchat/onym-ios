import XCTest
@testable import OnymIOS

/// Smoke tests for `ChatThreadViewController`. PR 5 ships an empty
/// shell — these tests pin the wiring contract the SwiftUI bridge
/// depends on:
///
///   - `viewDidLoad` doesn't crash.
///   - `update(groupName:)` writes through to a label the bridge
///     calls every render.
///   - The back / info buttons invoke their closures when tapped.
///
/// Message rendering, input, keyboard behavior arrive in later PRs;
/// the assertions here are intentionally narrow so they don't
/// constrain the layout work yet to come.
@MainActor
final class ChatThreadViewControllerTests: XCTestCase {

    func test_loadView_doesNotCrash() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        XCTAssertNotNil(vc.view)
    }

    func test_updateGroupName_writesThroughToTitleLabel() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(groupName: "Family")
        XCTAssertEqual(titleLabel(in: vc)?.text, "Family")
    }

    func test_updateGroupName_emptyFallsBackToChat() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        vc.update(groupName: "")
        XCTAssertEqual(titleLabel(in: vc)?.text, "Chat",
                       "empty group names fall back to the generic title so the bar isn't blank")
    }

    func test_backButtonTap_invokesOnBackClosure() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        var backCount = 0
        vc.onBack = { backCount += 1 }
        backButton(in: vc)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(backCount, 1)
    }

    func test_infoButtonTap_invokesOnShowMembersClosure() {
        let vc = ChatThreadViewController()
        vc.loadViewIfNeeded()
        var showCount = 0
        vc.onShowMembers = { showCount += 1 }
        infoButton(in: vc)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(showCount, 1)
    }

    // MARK: - Subview lookup
    //
    // The controller's subviews are private; tests reach them via
    // accessibility identifiers — same approach the create-group
    // UI tests use. Keeps the production code free of test seams.

    private func titleLabel(in vc: UIViewController) -> UILabel? {
        find(in: vc.view, identifier: "chat.title") as? UILabel
    }

    private func backButton(in vc: UIViewController) -> UIButton? {
        find(in: vc.view, identifier: "chat.back") as? UIButton
    }

    private func infoButton(in vc: UIViewController) -> UIButton? {
        find(in: vc.view, identifier: "chat.info") as? UIButton
    }

    private func find(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for sub in view.subviews {
            if let found = find(in: sub, identifier: identifier) { return found }
        }
        return nil
    }
}
