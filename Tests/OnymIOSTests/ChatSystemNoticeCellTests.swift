import XCTest
@testable import OnymIOS
@testable import OnymChatsUI
import OnymChatsCore

/// The thread's UI tests locate content by its text
/// (`app.staticTexts["Bob joined"]`), which only works while the cell
/// leaves its label exposed. Setting `isAccessibilityElement` on the cell
/// collapses the subtree and the label stops being a static text — the
/// notice then surfaces as a `.cell` and the query silently never
/// matches. These pin that contract, since the E2E pass that would
/// otherwise catch it needs live relays.
final class ChatSystemNoticeCellTests: XCTestCase {

    func test_cellDoesNotCollapseItsAccessibilitySubtree() {
        let cell = ChatSystemNoticeCell(
            style: .default,
            reuseIdentifier: ChatSystemNoticeCell.reuseID
        )
        cell.configure(event: .memberJoined(alias: "Bob"))

        XCTAssertFalse(
            cell.isAccessibilityElement,
            "collapsing the cell hides the label the UI tests match on"
        )
    }

    func test_labelCarriesTheNoticeTextAndIdentifier() {
        let cell = ChatSystemNoticeCell(
            style: .default,
            reuseIdentifier: ChatSystemNoticeCell.reuseID
        )
        let event = ChatSystemEvent.memberJoined(alias: "Bob")
        cell.configure(event: event)

        let label = Self.firstLabel(in: cell)
        // Compared against the event's own rendering rather than an
        // English literal: the sentence resolves through the string
        // catalog now, so hardcoding it here would pin the test to one
        // language — the same brittleness the UI-test page object was
        // rewritten to shed.
        XCTAssertEqual(label?.text, event.localizedText)
        XCTAssertTrue(label?.text?.contains("Bob") == true, "the alias survives every language")
        XCTAssertEqual(label?.accessibilityIdentifier, "chat.system_notice")
    }

    /// The rendered sentence must come from the event itself, so the
    /// thread pill and the chat-list subtitle can't drift.
    func test_noticeTextMatchesTheEventsLocalizedText() {
        let events: [ChatSystemEvent] = [
            .memberJoined(alias: "Bob"),
            .youJoined(groupName: "Book club")
        ]

        for event in events {
            let cell = ChatSystemNoticeCell(
                style: .default,
                reuseIdentifier: ChatSystemNoticeCell.reuseID
            )
            cell.configure(event: event)
            XCTAssertEqual(Self.firstLabel(in: cell)?.text, event.localizedText)
        }
    }

    private static func firstLabel(in view: UIView) -> UILabel? {
        if let label = view as? UILabel { return label }
        for subview in view.subviews {
            if let found = firstLabel(in: subview) { return found }
        }
        return nil
    }
}
