import XCTest
@testable import OnymIOS

/// Round-trip tests for `SwiftDataMessageStore`. Uses
/// `SwiftDataMessageStore.inMemory()` so the on-disk store under
/// Application Support isn't touched. Encrypted columns go through
/// the real `StorageEncryption` — same setup as
/// `SwiftDataGroupStoreTests`.
final class SwiftDataMessageStoreTests: XCTestCase {

    private var store: SwiftDataMessageStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataMessageStore.inMemory()
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    // MARK: - Round-trip

    func test_insertOrUpdate_thenList_roundtripsAllFields() async {
        let owner = IdentityID()
        let groupID = "aa".repeated(32)
        let msg = makeMessage(
            groupID: groupID,
            ownerIdentityID: owner,
            senderHex: "11".repeated(48),
            body: "hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .outgoing,
            status: .pending
        )

        let inserted = await store.insertOrUpdate(msg)
        XCTAssertTrue(inserted)

        let listed = await store.list(groupID: groupID)
        XCTAssertEqual(listed.count, 1)
        let first = listed[0]
        XCTAssertEqual(first.id, msg.id)
        XCTAssertEqual(first.groupID, groupID)
        XCTAssertEqual(first.ownerIdentityID, owner)
        XCTAssertEqual(first.senderBlsPubkeyHex, "11".repeated(48))
        XCTAssertEqual(first.body, "hello")
        XCTAssertEqual(first.sentAt, msg.sentAt)
        XCTAssertEqual(first.direction, .outgoing)
        XCTAssertEqual(first.status, .pending)
        XCTAssertEqual(first.groupType, .tyranny)
    }

    func test_insertOrUpdate_sameID_updatesInPlace() async {
        let msg = makeMessage(body: "draft", status: .pending)
        _ = await store.insertOrUpdate(msg)

        // Same id, status flipped: should overwrite, not duplicate.
        let updated = ChatMessage(
            id: msg.id,
            groupID: msg.groupID,
            ownerIdentityID: msg.ownerIdentityID,
            senderBlsPubkeyHex: msg.senderBlsPubkeyHex,
            body: "draft",
            sentAt: msg.sentAt,
            direction: .outgoing,
            status: .sent,
            groupType: .tyranny
        )
        let inserted = await store.insertOrUpdate(updated)
        XCTAssertFalse(inserted, "second insert on same id must report update, not insert")

        let listed = await store.list(groupID: msg.groupID)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].status, .sent)
    }

    // MARK: - list

    func test_list_filtersByGroupID() async {
        let groupA = "aa".repeated(32)
        let groupB = "bb".repeated(32)
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "in A"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupB, body: "in B"))

        let inA = await store.list(groupID: groupA)
        let inB = await store.list(groupID: groupB)
        XCTAssertEqual(inA.count, 1)
        XCTAssertEqual(inB.count, 1)
        XCTAssertEqual(inA[0].body, "in A")
        XCTAssertEqual(inB[0].body, "in B")
    }

    func test_list_sortsBySentAtAscending() async {
        let groupID = "cc".repeated(32)
        let older = makeMessage(
            groupID: groupID,
            body: "older",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = makeMessage(
            groupID: groupID,
            body: "newer",
            sentAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        // Insert out of order — sort must come from the store.
        _ = await store.insertOrUpdate(newer)
        _ = await store.insertOrUpdate(older)

        let listed = await store.list(groupID: groupID)
        XCTAssertEqual(listed.map(\.body), ["older", "newer"])
    }

    func test_list_unknownGroupID_returnsEmpty() async {
        let listed = await store.list(groupID: "ff".repeated(32))
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - updateStatus

    func test_updateStatus_flipsOnlyStatusColumn() async {
        let msg = makeMessage(body: "in flight", status: .pending)
        _ = await store.insertOrUpdate(msg)

        await store.updateStatus(id: msg.id, status: .sent)

        let listed = await store.list(groupID: msg.groupID)
        XCTAssertEqual(listed[0].status, .sent)
        XCTAssertEqual(listed[0].body, "in flight",
                       "body must survive a status-only update")
    }

    func test_updateStatus_unknownID_isNoOp() async {
        await store.updateStatus(id: UUID(), status: .sent)
        // No throw, no row, no surprise.
        let listed = await store.list(groupID: "aa".repeated(32))
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - delete

    func test_delete_removesRow() async {
        let msg = makeMessage()
        _ = await store.insertOrUpdate(msg)
        await store.delete(id: msg.id)
        let listed = await store.list(groupID: msg.groupID)
        XCTAssertTrue(listed.isEmpty)
    }

    func test_deleteGroup_removesAllMessagesForGroup() async {
        let groupA = "aa".repeated(32)
        let groupB = "bb".repeated(32)
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "a1"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "a2"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupB, body: "b1"))

        await store.deleteGroup(groupID: groupA)
        let remainingA = await store.list(groupID: groupA)
        let remainingB = await store.list(groupID: groupB)
        XCTAssertTrue(remainingA.isEmpty)
        XCTAssertEqual(remainingB.count, 1)
    }

    func test_deleteOwner_removesAllMessagesForIdentity() async {
        let aliceID = IdentityID()
        let bobID = IdentityID()
        let groupA = "aa".repeated(32)
        _ = await store.insertOrUpdate(
            makeMessage(groupID: groupA, ownerIdentityID: aliceID, body: "alice")
        )
        _ = await store.insertOrUpdate(
            makeMessage(groupID: groupA, ownerIdentityID: bobID, body: "bob")
        )

        await store.deleteOwner(aliceID.rawValue.uuidString)

        let remaining = await store.list(groupID: groupA)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].body, "bob")
    }

    // MARK: - Helpers

    private func makeMessage(
        id: UUID = UUID(),
        groupID: String = "aa".repeated(32),
        ownerIdentityID: IdentityID = IdentityID(),
        senderHex: String = "11".repeated(48),
        body: String = "hi",
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        direction: MessageDirection = .outgoing,
        status: MessageStatus = .sent
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            senderBlsPubkeyHex: senderHex,
            body: body,
            sentAt: sentAt,
            direction: direction,
            status: status,
            groupType: .tyranny
        )
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
