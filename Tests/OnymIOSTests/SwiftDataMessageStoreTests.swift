import XCTest
@testable import OnymIOS

/// Round-trip tests for `SwiftDataMessageStore`. Uses
/// `SwiftDataMessageStore.inMemory()` so the on-disk store under
/// Application Support isn't touched. Encrypted columns go through
/// the real `StorageEncryption` — same setup as
/// `SwiftDataGroupStoreTests`. Rows are scoped by `(id, owner)`, so
/// reads/mutations name the owning identity.
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

        let listed = await store.list(groupID: groupID, ownerIDString: owner.rawValue.uuidString)
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
        XCTAssertNil(first.replyToMessageID,
                     "a non-reply message round-trips with no reply target")
    }

    func test_insertOrUpdate_imageAttachment_roundtrips() async {
        let owner = IdentityID()
        let groupID = "aa".repeated(32)
        let attachment = ChatImageAttachment(
            sha256: "cd".repeated(32),
            mimeType: "image/jpeg",
            byteSize: 51_234,
            width: 1024,
            height: 768,
            encKey: Data(repeating: 0x7, count: 32),
            blurhash: "LEHV6nWB2yk8",
            server: "https://blossom.onym.app"
        )
        let msg = ChatMessage(
            id: UUID(),
            groupID: groupID,
            ownerIdentityID: owner,
            senderBlsPubkeyHex: "11".repeated(48),
            body: "caption",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            direction: .outgoing,
            status: .sent,
            replyToMessageID: nil,
            groupType: .tyranny,
            imageAttachment: attachment
        )
        _ = await store.insertOrUpdate(msg)

        let listed = await store.list(groupID: groupID, ownerIDString: owner.rawValue.uuidString)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].imageAttachment, attachment)
        XCTAssertEqual(listed[0].body, "caption")
    }

    func test_insertOrUpdate_noAttachment_roundtripsAsNil() async {
        let msg = makeMessage(body: "text only")
        _ = await store.insertOrUpdate(msg)
        let listed = await store.list(
            groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertNil(listed[0].imageAttachment)
    }

    func test_insertOrUpdate_replyRef_roundtrips() async {
        let groupID = "aa".repeated(32)
        let target = UUID()
        let reply = makeMessage(groupID: groupID, body: "agreed", replyToMessageID: target)

        _ = await store.insertOrUpdate(reply)

        let listed = await store.list(groupID: groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed.first?.replyToMessageID, target,
                       "the reply target id must survive the encrypted-store round-trip")
    }

    func test_insertOrUpdate_sameID_updatesInPlace() async {
        let msg = makeMessage(body: "draft", status: .pending)
        _ = await store.insertOrUpdate(msg)

        // Same id + owner, status flipped: should overwrite, not duplicate.
        let updated = ChatMessage(
            id: msg.id,
            groupID: msg.groupID,
            ownerIdentityID: msg.ownerIdentityID,
            senderBlsPubkeyHex: msg.senderBlsPubkeyHex,
            body: "draft",
            sentAt: msg.sentAt,
            direction: .outgoing,
            status: .sent,
            replyToMessageID: nil,
            groupType: .tyranny
        )
        let inserted = await store.insertOrUpdate(updated)
        XCTAssertFalse(inserted, "second insert on same id+owner must report update, not insert")

        let listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].status, .sent)
    }

    /// Regression: the same wire message id received by two local
    /// identities keeps a row per identity — the second arrival must
    /// not steal (or flip the direction of) the first's row.
    func test_insertOrUpdate_sameID_twoOwners_keepsBothRows() async {
        let groupID = "aa".repeated(32)
        let sharedID = UUID()
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        let outgoing = makeMessage(
            id: sharedID, groupID: groupID, ownerIdentityID: ownerA,
            body: "mine", direction: .outgoing
        )
        let incoming = makeMessage(
            id: sharedID, groupID: groupID, ownerIdentityID: ownerB,
            body: "mine", direction: .incoming
        )

        let insertedA = await store.insertOrUpdate(outgoing)
        let insertedB = await store.insertOrUpdate(incoming)
        XCTAssertTrue(insertedA)
        XCTAssertTrue(insertedB,
                      "second owner is a fresh insert, not an in-place overwrite")

        let aRows = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let bRows = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertEqual(aRows.map(\.direction), [.outgoing], "A's own message stays outgoing")
        XCTAssertEqual(bRows.map(\.direction), [.incoming], "B sees it as incoming")
    }

    // MARK: - list

    func test_list_filtersByGroupID() async {
        let groupA = "aa".repeated(32)
        let groupB = "bb".repeated(32)
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "in A"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupB, body: "in B"))

        let inA = await store.list(groupID: groupA, ownerIDString: kOwner.rawValue.uuidString)
        let inB = await store.list(groupID: groupB, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(inA.count, 1)
        XCTAssertEqual(inB.count, 1)
        XCTAssertEqual(inA[0].body, "in A")
        XCTAssertEqual(inB[0].body, "in B")
    }

    func test_list_filtersByOwner() async {
        let groupID = "aa".repeated(32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerA, body: "a"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerB, body: "b"))

        let a = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let b = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertEqual(a.map(\.body), ["a"])
        XCTAssertEqual(b.map(\.body), ["b"])
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

        let listed = await store.list(groupID: groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed.map(\.body), ["older", "newer"])
    }

    func test_list_unknownGroupID_returnsEmpty() async {
        let listed = await store.list(
            groupID: "ff".repeated(32),
            ownerIDString: kOwner.rawValue.uuidString
        )
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - updateStatus

    func test_updateStatus_flipsOnlyStatusColumn() async {
        let msg = makeMessage(body: "in flight", status: .pending)
        _ = await store.insertOrUpdate(msg)

        await store.updateStatus(
            id: msg.id, ownerIDString: kOwner.rawValue.uuidString,
            status: .sent, failureReason: nil
        )

        let listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed[0].status, .sent)
        XCTAssertEqual(listed[0].body, "in flight",
                       "body must survive a status-only update")
    }

    func test_updateStatus_failureReason_roundTripsAndClears() async {
        let msg = makeMessage(body: "doomed", status: .pending)
        _ = await store.insertOrUpdate(msg)

        await store.updateStatus(
            id: msg.id, ownerIDString: kOwner.rawValue.uuidString,
            status: .failed, failureReason: .secureConnectionFailed
        )
        var listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertEqual(listed[0].status, .failed)
        XCTAssertEqual(listed[0].failureReason, .secureConnectionFailed,
                       "the reason must survive the store round-trip")

        // Retry flips back to pending with a nil reason — the stale
        // explanation must clear.
        await store.updateStatus(
            id: msg.id, ownerIDString: kOwner.rawValue.uuidString,
            status: .pending, failureReason: nil
        )
        listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertNil(listed[0].failureReason)
    }

    func test_updateStatus_unknownID_isNoOp() async {
        await store.updateStatus(
            id: UUID(), ownerIDString: kOwner.rawValue.uuidString,
            status: .sent, failureReason: nil
        )
        // No throw, no row, no surprise.
        let listed = await store.list(groupID: "aa".repeated(32), ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - delete

    func test_delete_removesRow() async {
        let msg = makeMessage()
        _ = await store.insertOrUpdate(msg)
        await store.delete(id: msg.id, ownerIDString: kOwner.rawValue.uuidString)
        let listed = await store.list(groupID: msg.groupID, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertTrue(listed.isEmpty)
    }

    func test_delete_isScopedToOwner() async {
        let groupID = "aa".repeated(32)
        let sharedID = UUID()
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeMessage(id: sharedID, groupID: groupID, ownerIdentityID: ownerA))
        _ = await store.insertOrUpdate(makeMessage(id: sharedID, groupID: groupID, ownerIdentityID: ownerB))

        await store.delete(id: sharedID, ownerIDString: ownerA.rawValue.uuidString)

        let aRows = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let bRows = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertTrue(aRows.isEmpty)
        XCTAssertEqual(bRows.count, 1, "deleting one identity's copy leaves the other's row")
    }

    func test_deleteGroup_removesAllMessagesForGroup() async {
        let groupA = "aa".repeated(32)
        let groupB = "bb".repeated(32)
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "a1"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupA, body: "a2"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupB, body: "b1"))

        await store.deleteGroup(groupID: groupA, ownerIDString: kOwner.rawValue.uuidString)
        let remainingA = await store.list(groupID: groupA, ownerIDString: kOwner.rawValue.uuidString)
        let remainingB = await store.list(groupID: groupB, ownerIDString: kOwner.rawValue.uuidString)
        XCTAssertTrue(remainingA.isEmpty)
        XCTAssertEqual(remainingB.count, 1)
    }

    func test_deleteGroup_isScopedToOwner() async {
        let groupID = "aa".repeated(32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerA, body: "a"))
        _ = await store.insertOrUpdate(makeMessage(groupID: groupID, ownerIdentityID: ownerB, body: "b"))

        await store.deleteGroup(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)

        let aRows = await store.list(groupID: groupID, ownerIDString: ownerA.rawValue.uuidString)
        let bRows = await store.list(groupID: groupID, ownerIDString: ownerB.rawValue.uuidString)
        XCTAssertTrue(aRows.isEmpty)
        XCTAssertEqual(bRows.map(\.body), ["b"],
                       "deleting one identity's thread leaves the other's copy of the group")
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

        let alice = await store.list(groupID: groupA, ownerIDString: aliceID.rawValue.uuidString)
        let bob = await store.list(groupID: groupA, ownerIDString: bobID.rawValue.uuidString)
        XCTAssertTrue(alice.isEmpty)
        XCTAssertEqual(bob.map(\.body), ["bob"])
    }

    // MARK: - Helpers

    private func makeMessage(
        id: UUID = UUID(),
        groupID: String = "aa".repeated(32),
        ownerIdentityID: IdentityID = kOwner,
        senderHex: String = "11".repeated(48),
        body: String = "hi",
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        direction: MessageDirection = .outgoing,
        status: MessageStatus = .sent,
        replyToMessageID: UUID? = nil
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
            replyToMessageID: replyToMessageID,
            groupType: .tyranny
        )
    }
}

/// Shared default owner for the single-identity tests above. File-scope
/// so `makeMessage`'s default argument can reference it.
private let kOwner = IdentityID()

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
