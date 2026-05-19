import XCTest
@testable import OnymIOS

/// Behavioral tests for `ChatInputPanelView`. The two contracts
/// other PRs depend on:
///
///   - Send button enabled iff the text view has non-whitespace
///     content. PR 8's `SendMessageInteractor` wiring will trust
///     this and skip its own empty-body guard.
///   - Text view height grows with content, capped at 3 lines.
///     Beyond the cap the text view scrolls internally instead of
///     pushing the message list further up.
@MainActor
final class ChatInputPanelViewTests: XCTestCase {

    // MARK: - Send-button enable state

    func test_initialState_sendButtonDisabled() {
        let panel = ChatInputPanelView()
        XCTAssertFalse(sendButton(in: panel).isEnabled,
                       "empty composer must not let the send button fire")
    }

    func test_setText_nonEmpty_enablesSend() {
        let panel = ChatInputPanelView()
        panel.text = "hi"
        XCTAssertTrue(sendButton(in: panel).isEnabled)
    }

    func test_setText_emptyAgain_disablesSend() {
        let panel = ChatInputPanelView()
        panel.text = "hi"
        XCTAssertTrue(sendButton(in: panel).isEnabled)
        panel.text = ""
        XCTAssertFalse(sendButton(in: panel).isEnabled)
    }

    func test_setText_whitespaceOnly_disablesSend() {
        // Whitespace-only input must leave the button disabled —
        // it's the canonical signal to the user that tapping
        // wouldn't send anything. (`tappedSend` already no-ops on
        // whitespace; this asserts the button's enable state
        // matches that behavior.)
        let panel = ChatInputPanelView()
        panel.text = "   \n   "
        XCTAssertFalse(sendButton(in: panel).isEnabled)
    }

    // MARK: - Send tap

    func test_tappingSend_invokesClosure_withTrimmedText() {
        let panel = ChatInputPanelView()
        var received: String?
        panel.onSendTapped = { received = $0 }
        panel.text = "   hello   "
        sendButton(in: panel).sendActions(for: .touchUpInside)
        XCTAssertEqual(received, "hello",
                       "send should trim leading/trailing whitespace")
    }

    func test_tappingSend_emptyText_isNoOp() {
        // Belt + braces: the button is disabled when empty, but if
        // a future caller forces a tap programmatically the
        // closure must still not fire on empty input.
        let panel = ChatInputPanelView()
        var fired = false
        panel.onSendTapped = { _ in fired = true }
        panel.text = "   "  // whitespace-only also counts as empty
        sendButton(in: panel).sendActions(for: .touchUpInside)
        XCTAssertFalse(fired)
    }

    // MARK: - Auto-height
    //
    // Asserting absolute pixel values is brittle — UITextView's
    // empty-state height doesn't exactly match the obvious
    // `font.lineHeight + insets` formula (it's typically a point
    // larger). All height tests below are *relative*: empty,
    // single-line, multi-line, and capped states compared against
    // each other rather than against hard-coded numbers.

    // Each height test hosts the panel in a real `UIWindow` so
    // the constraint engine actually drives the height constraint
    // — without a superview, `layoutIfNeeded()` is a no-op and
    // the constraint stays at its initial constant, making any
    // pre/post comparison pass trivially. (PR 7 review point #2.)

    func test_singleLineText_doesNotGrowBeyondEmpty() {
        // Short text fits on one line, so the panel height must
        // match the empty state's height — auto-grow doesn't kick
        // in until the second line.
        let panel = makePanelInWindow(width: 320)
        let emptyHeight = textViewHeight(in: panel)
        // Sanity-check: the constraint was actually driven by the
        // layout pass. A trivial "both reads return 36" failure
        // mode would slip past the comparison below.
        XCTAssertGreaterThan(emptyHeight, 0)

        panel.text = "hi"
        panel.layoutIfNeeded()
        XCTAssertEqual(textViewHeight(in: panel), emptyHeight, accuracy: 0.5)
    }

    func test_multiLineText_growsBeyondSingleLine() {
        let panel = makePanelInWindow(width: 320)
        let emptyHeight = textViewHeight(in: panel)

        panel.text = "line 1\nline 2"
        panel.layoutIfNeeded()
        XCTAssertGreaterThan(textViewHeight(in: panel), emptyHeight + 1,
                             "two lines of text must grow the panel")
    }

    func test_textGrows_capsAtMaxLineCount() {
        // Three vs ten lines should produce the *same* height —
        // anything past the cap scrolls internally instead of
        // pushing the panel taller.
        let panel = makePanelInWindow(width: 400)

        panel.text = "1\n2\n3"
        panel.layoutIfNeeded()
        let threeLineHeight = textViewHeight(in: panel)

        panel.text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        panel.layoutIfNeeded()
        let tenLineHeight = textViewHeight(in: panel)

        XCTAssertEqual(tenLineHeight, threeLineHeight, accuracy: 0.5,
                       "panel must stop growing past the line cap")
    }

    /// Hosts the panel in a real `UIWindow` of the requested width
    /// with the panel pinned to leading / trailing / bottom. The
    /// constraint engine drives the panel's intrinsic height to a
    /// real value, so subsequent `textViewHeight(in:)` reads
    /// reflect what production layout would produce.
    private func makePanelInWindow(width: CGFloat) -> ChatInputPanelView {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 600))
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false

        let panel = ChatInputPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        host.view.layoutIfNeeded()
        return panel
    }

    // MARK: - Subview lookup

    private func sendButton(in panel: ChatInputPanelView) -> UIButton {
        guard let b = find(in: panel, identifier: "chat.input.send") as? UIButton else {
            fatalError("send button not found")
        }
        return b
    }

    private func textView(in panel: ChatInputPanelView) -> UITextView {
        guard let tv = find(in: panel, identifier: "chat.input.textview") as? UITextView else {
            fatalError("text view not found")
        }
        return tv
    }

    private func textViewHeight(in panel: ChatInputPanelView) -> CGFloat {
        // The text view's height is governed by an internal
        // constraint. Read the resolved height via the constraint
        // rather than the live frame — the latter can be stale
        // until the next layout pass.
        let tv = textView(in: panel)
        return tv.constraints.first { $0.firstAttribute == .height }?.constant
            ?? tv.bounds.height
    }

    private func find(in view: UIView, identifier: String) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for sub in view.subviews {
            if let found = find(in: sub, identifier: identifier) { return found }
        }
        return nil
    }
}
