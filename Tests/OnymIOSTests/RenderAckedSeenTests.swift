import XCTest
@testable import OnymIOS

/// PR-7 of the reconnect design (F7): `.read` receipts and unread-badge
/// clearing must be driven by *actual on-screen rendering*, not by data
/// processing. `ChatThreadViewController.onMessagesSeen` fires only for
/// incoming bubbles that are visible while the view is in a window and
/// the app active — and each message at most once.
@MainActor
final class RenderAckedSeenTests: XCTestCase {
    private func mountedController() -> ChatThreadViewController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
        let vc = ChatThreadViewController()
        window.rootViewController = vc
        window.isHidden = false
        return vc
    }

    private func incoming(_ body: String, at seconds: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: UUID(), groupID: String(repeating: "aa", count: 32),
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: String(repeating: "11", count: 48), body: body,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            direction: .incoming, status: .received,
            replyToMessageID: nil, groupType: .tyranny
        )
    }

    private func outgoing(_ body: String, at seconds: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: UUID(), groupID: String(repeating: "aa", count: 32),
            ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: String(repeating: "22", count: 48), body: body,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            direction: .outgoing, status: .sent,
            replyToMessageID: nil, groupType: .tyranny
        )
    }

    private func pump(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func test_visibleIncomingMessages_areReportedSeen_once() {
        let vc = mountedController()
        var seen: [ChatMessage] = []
        vc.onMessagesSeen = { seen.append(contentsOf: $0) }

        let msgs = [incoming("one", at: 0), incoming("two", at: 1)]
        vc.update(messages: msgs)
        vc.view.layoutIfNeeded()
        pump()

        XCTAssertEqual(Set(seen.map(\.id)), Set(msgs.map(\.id)),
                       "visible incoming bubbles must be reported seen")

        // Re-report triggers (scroll, appear) must not duplicate.
        seen.removeAll()
        vc.reportVisibleIncomingMessages()
        XCTAssertTrue(seen.isEmpty, "each message is reported at most once")
    }

    func test_outgoingMessages_areNeverReportedSeen() {
        let vc = mountedController()
        var seen: [ChatMessage] = []
        vc.onMessagesSeen = { seen.append(contentsOf: $0) }

        vc.update(messages: [outgoing("mine", at: 0), incoming("theirs", at: 1)])
        vc.view.layoutIfNeeded()
        pump()

        XCTAssertEqual(seen.map(\.body), ["theirs"],
                       "own outgoing messages are not read-receipt subjects")
    }

    func test_nothingReported_whileNotVisible_reportedOnBecomeActive() {
        let vc = mountedController()
        var seen: [ChatMessage] = []
        vc.onMessagesSeen = { seen.append(contentsOf: $0) }
        vc.canScrollNow = { false }  // "backgrounded": not user-visible

        vc.update(messages: [incoming("bg message", at: 0)])
        vc.view.layoutIfNeeded()
        pump()
        XCTAssertTrue(seen.isEmpty,
                      "a message rendered while backgrounded must NOT be marked read (F7)")

        // Foreground: now a person can actually see it.
        vc.canScrollNow = { true }
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        pump()
        XCTAssertEqual(seen.map(\.body), ["bg message"],
                       "the message must be reported once the app is active and it's on screen")
    }

    func test_messageBelowTheFold_reportedOnlyWhenScrolledIntoView() {
        let vc = mountedController()
        var seen: [ChatMessage] = []
        vc.onMessagesSeen = { seen.append(contentsOf: $0) }

        // Long thread: cold open lands at the bottom, so the OLDEST
        // messages are off screen.
        let msgs = (0..<60).map { incoming("m\($0)", at: TimeInterval($0)) }
        vc.update(messages: msgs)
        vc.view.layoutIfNeeded()
        pump()

        let table = vc.view.subviews.compactMap { $0 as? UITableView }.first
            ?? vc.view.subviews.flatMap(\.subviews).compactMap { $0 as? UITableView }.first!
        XCTAssertFalse(seen.contains { $0.body == "m0" },
                       "a bubble below/above the fold is not seen")
        let initiallySeen = Set(seen.map(\.id))

        // Scroll to the top — the oldest bubbles become visible.
        table.setContentOffset(.zero, animated: false)
        table.layoutIfNeeded()
        vc.reportVisibleIncomingMessages()
        pump(0.1)

        XCTAssertTrue(seen.contains { $0.body == "m0" },
                      "scrolling a bubble on screen must report it seen")
        XCTAssertGreaterThan(seen.count, initiallySeen.count)
    }
}
