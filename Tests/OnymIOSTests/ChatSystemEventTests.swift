import XCTest
@testable import OnymIOS
import OnymChain
import OnymFoundation
import OnymGroup
import OnymIdentity
import OnymChatsCore

/// Covers the system-message surface introduced when join requests moved
/// into the chat thread: persistence of the new `systemEvent` column,
/// the unread-count carve-out, and the idempotence that keeps relay
/// replays from stacking duplicate "X joined" rows.
final class ChatSystemEventTests: XCTestCase {

    private var store: SwiftDataMessageStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataMessageStore.inMemory()
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    // MARK: - Persistence

    func test_systemEvent_roundTripsThroughTheStore() async {
        let owner = IdentityID()
        let groupID = String(repeating: "aa", count: 32)
        let message = makeSystemMessage(
            groupID: groupID,
            owner: owner,
            event: .memberJoined(alias: "Alice")
        )

        _ = await store.insertOrUpdate(message)
        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )

        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.systemEvent, .memberJoined(alias: "Alice"))
        XCTAssertTrue(listed.first?.isSystem == true)
    }

    func test_youJoined_roundTripsThroughTheStore() async {
        let owner = IdentityID()
        let groupID = String(repeating: "bb", count: 32)
        let message = makeSystemMessage(
            groupID: groupID,
            owner: owner,
            event: .youJoined(groupName: "Book club")
        )

        _ = await store.insertOrUpdate(message)
        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )

        XCTAssertEqual(listed.first?.systemEvent, .youJoined(groupName: "Book club"))
    }

    func test_ordinaryMessage_hasNoSystemEvent() async {
        let owner = IdentityID()
        let groupID = String(repeating: "cc", count: 32)
        let message = ChatMessage(
            id: UUID(),
            groupID: groupID,
            ownerIdentityID: owner,
            senderBlsPubkeyHex: String(repeating: "11", count: 48),
            body: "hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .incoming,
            status: .received,
            replyToMessageID: nil,
            groupType: .tyranny
        )

        _ = await store.insertOrUpdate(message)
        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )

        XCTAssertNil(listed.first?.systemEvent)
        XCTAssertFalse(listed.first?.isSystem == true)
    }

    // MARK: - Unread count

    /// "Alice joined" lands on every member's device at once. Counting it
    /// as unread would light up a badge on a chat where nobody said
    /// anything.
    func test_unreadCount_ignoresSystemNotices() async {
        let owner = IdentityID()
        let groupID = String(repeating: "dd", count: 32)
        let since = Date(timeIntervalSince1970: 1_600_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await store.insertOrUpdate(
            makeSystemMessage(
                groupID: groupID,
                owner: owner,
                event: .memberJoined(alias: "Alice"),
                sentAt: later
            )
        )

        let onlySystem = await store.unreadCount(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString,
            since: since
        )
        XCTAssertEqual(onlySystem, 0, "a system notice must not count as unread")

        // A real incoming message alongside it still counts.
        _ = await store.insertOrUpdate(
            ChatMessage(
                id: UUID(),
                groupID: groupID,
                ownerIdentityID: owner,
                senderBlsPubkeyHex: String(repeating: "11", count: 48),
                body: "hi",
                sentAt: later,
                direction: .incoming,
                status: .received,
                replyToMessageID: nil,
                groupType: .tyranny
            )
        )

        let withReal = await store.unreadCount(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString,
            since: since
        )
        XCTAssertEqual(withReal, 1, "a real incoming message must still count")
    }

    // MARK: - Chat-list preview

    func test_chatListPreview_readsAsASentence_withoutTheYouPrefix() {
        let joined = makeSystemMessage(
            groupID: String(repeating: "ee", count: 32),
            owner: IdentityID(),
            event: .memberJoined(alias: "Alice")
        )
        // The system row is stored as `.incoming`, but the point is that
        // no "You: " prefix is ever applied to a notice.
        XCTAssertFalse(joined.chatListPreview.hasPrefix("You: "))
        XCTAssertTrue(joined.chatListPreview.contains("Alice"))
    }

    // MARK: - Idempotence

    /// Relays replay the full inbox on every reconnect. The recorder's
    /// derived ids are the backstop behind the callers' dedup guards: the
    /// same join recorded twice must collapse to one row, not stack a
    /// fresh "Alice joined" on every launch.
    func test_recordMemberJoined_isIdempotentAcrossReplays() async {
        let owner = IdentityID()
        let groupID = String(repeating: "ff", count: 32)
        let repository = MessageRepository(store: store)
        let recorder = ChatSystemEventRecorder(messageRepository: repository)
        let joiner = String(repeating: "22", count: 48)

        for _ in 0..<3 {
            await recorder.recordMemberJoined(
                groupID: groupID,
                ownerIdentityID: owner,
                groupType: .tyranny,
                joinerBlsPubkeyHex: joiner,
                alias: "Alice",
                at: Date()
            )
        }

        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )
        XCTAssertEqual(listed.count, 1, "replays must collapse onto one notice")
        XCTAssertEqual(listed.first?.systemEvent, .memberJoined(alias: "Alice"))
    }

    func test_recordMemberJoined_distinctJoinersGetDistinctRows() async {
        let owner = IdentityID()
        let groupID = String(repeating: "ab", count: 32)
        let repository = MessageRepository(store: store)
        let recorder = ChatSystemEventRecorder(messageRepository: repository)

        await recorder.recordMemberJoined(
            groupID: groupID,
            ownerIdentityID: owner,
            groupType: .tyranny,
            joinerBlsPubkeyHex: String(repeating: "22", count: 48),
            alias: "Alice",
            at: Date()
        )
        await recorder.recordMemberJoined(
            groupID: groupID,
            ownerIdentityID: owner,
            groupType: .tyranny,
            joinerBlsPubkeyHex: String(repeating: "33", count: 48),
            alias: "Bob",
            at: Date()
        )

        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )
        XCTAssertEqual(listed.count, 2)
    }

    func test_recordYouJoined_isIdempotent() async {
        let owner = IdentityID()
        let groupID = String(repeating: "ba", count: 32)
        let repository = MessageRepository(store: store)
        let recorder = ChatSystemEventRecorder(messageRepository: repository)

        for _ in 0..<2 {
            await recorder.recordYouJoined(
                groupID: groupID,
                ownerIdentityID: owner,
                groupType: .tyranny,
                groupName: "Book club",
                ownBlsPubkeyHex: String(repeating: "44", count: 48),
                at: Date()
            )
        }

        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )
        XCTAssertEqual(listed.count, 1)
    }

    /// The *recorder* scopes rows per owner: two identities in the same
    /// group each get their own notice rather than sharing one row.
    ///
    /// Scope note — this asserts the recorder, not end-to-end delivery.
    /// `IncomingMessageDispatcher.applyAnnouncement` resolves the target
    /// with `groups.first(where: { $0.groupIDData == ... })`, so when two
    /// local identities are both in one group only the first is updated
    /// and only it gets a notice. That's a pre-existing dispatcher
    /// limitation — it truncates the roster update (`memberProfiles`) the
    /// same way — and is out of scope here; this test deliberately
    /// exercises `ChatSystemEventRecorder` directly so it isn't read as
    /// coverage for a delivery guarantee that doesn't hold.
    func test_recordMemberJoined_scopesRowsPerOwner() async {
        let groupID = String(repeating: "cd", count: 32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        let repository = MessageRepository(store: store)
        let recorder = ChatSystemEventRecorder(messageRepository: repository)
        let joiner = String(repeating: "55", count: 48)

        for owner in [ownerA, ownerB] {
            await recorder.recordMemberJoined(
                groupID: groupID,
                ownerIdentityID: owner,
                groupType: .tyranny,
                joinerBlsPubkeyHex: joiner,
                alias: "Alice",
                at: Date()
            )
        }

        for owner in [ownerA, ownerB] {
            let listed = await store.list(
                groupID: groupID,
                ownerIDString: owner.rawValue.uuidString
            )
            XCTAssertEqual(listed.count, 1, "each identity keeps its own notice")
        }
    }

    // MARK: - Alias sanitising

    /// Aliases are self-asserted and arrive unchecked. The request row
    /// trims before rendering, but a notice is written into *permanent*
    /// history — an empty alias would leave " joined" in the thread with
    /// no way to correct it.
    func test_blankAlias_fallsBackRatherThanRenderingAsSpace() async {
        let owner = IdentityID()
        let groupID = String(repeating: "de", count: 32)
        let recorder = ChatSystemEventRecorder(
            messageRepository: MessageRepository(store: store)
        )

        await recorder.recordMemberJoined(
            groupID: groupID,
            ownerIdentityID: owner,
            groupType: .tyranny,
            joinerBlsPubkeyHex: String(repeating: "66", count: 48),
            alias: "   ",
            at: Date()
        )

        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )
        guard case .memberJoined(let alias)? = listed.first?.systemEvent else {
            return XCTFail("expected a memberJoined notice")
        }
        // The *stored* value keeps what arrived, which for a blank alias
        // is nothing. Resolving the placeholder before storing would
        // freeze one language into permanent history — the row would
        // still read "(unnamed)" after the device switched to French,
        // with no way to correct it.
        XCTAssertTrue(alias.isEmpty, "the placeholder belongs at render time, not in the row")

        // What the user sees still falls back, which is the part that
        // matters: no " joined" with a leading space, ever.
        let rendered = listed.first?.chatListPreview ?? ""
        XCTAssertFalse(rendered.hasPrefix(" "))
        XCTAssertFalse(rendered.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertTrue(rendered.contains("joined"))
    }

    func test_blankGroupName_fallsBack() async {
        let owner = IdentityID()
        let groupID = String(repeating: "ef", count: 32)
        let recorder = ChatSystemEventRecorder(
            messageRepository: MessageRepository(store: store)
        )

        await recorder.recordYouJoined(
            groupID: groupID,
            ownerIdentityID: owner,
            groupType: .tyranny,
            groupName: "",
            ownBlsPubkeyHex: String(repeating: "77", count: 48),
            at: Date()
        )

        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )
        guard case .youJoined(let name)? = listed.first?.systemEvent else {
            return XCTFail("expected a youJoined notice")
        }
        // Stored raw for the same reason as the alias above.
        XCTAssertTrue(name.isEmpty, "the placeholder belongs at render time, not in the row")

        let rendered = listed.first?.chatListPreview ?? ""
        XCTAssertFalse(rendered.hasSuffix(" "), "no trailing space where the name should be")
        XCTAssertTrue(rendered.contains("You joined"))
    }

    /// A row carrying a system event it cannot decode is dropped, not
    /// degraded.
    ///
    /// After a downgrade an unknown `kind` fails to decode. Falling back
    /// to `systemEvent: nil` renders the row as an ordinary *empty
    /// bubble* attributed to the joiner — a message nobody sent. Hiding
    /// it says less, but it says nothing false.
    func test_undecodableSystemEvent_dropsTheRowRatherThanShowingAnEmptyBubble() async {
        let owner = IdentityID()
        let groupID = String(repeating: "cd", count: 32)
        let recorder = ChatSystemEventRecorder(
            messageRepository: MessageRepository(store: store)
        )
        await recorder.recordMemberJoined(
            groupID: groupID,
            ownerIdentityID: owner,
            groupType: .tyranny,
            joinerBlsPubkeyHex: String(repeating: "88", count: 48),
            alias: "Alice",
            at: Date()
        )
        let before = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )
        XCTAssertEqual(before.count, 1)

        // Rewrite the stored event as a kind this build does not know.
        await store.overwriteSystemEventForTests(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString,
            json: #"{"kind":"member_left_in_a_future_version"}"#
        )

        let listed = await store.list(
            groupID: groupID,
            ownerIDString: owner.rawValue.uuidString
        )
        XCTAssertTrue(listed.isEmpty, "an unreadable notice must not render as a blank message")
    }

    // MARK: - Helpers

    private func makeSystemMessage(
        groupID: String,
        owner: IdentityID,
        event: ChatSystemEvent,
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            groupID: groupID,
            ownerIdentityID: owner,
            senderBlsPubkeyHex: String(repeating: "22", count: 48),
            body: "",
            sentAt: sentAt,
            direction: .incoming,
            status: .received,
            replyToMessageID: nil,
            groupType: .tyranny,
            systemEvent: event
        )
    }
}
