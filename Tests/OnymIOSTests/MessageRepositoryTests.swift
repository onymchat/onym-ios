import XCTest
@testable import OnymIOS

/// Reactive-surface tests for `MessageRepository`. Backed by an
/// in-memory `MessageStore` fake — same pattern as
/// `GroupRepositoryTests`.
final class MessageRepositoryTests: XCTestCase {

    private let groupA = "aa".repeated(32)
    private let groupB = "bb".repeated(32)

    // MARK: - snapshots emission

    func test_snapshots_replaysCurrentOnSubscribe() async {
        let store = InMemoryMessageStore()
        let seeded = makeMessage(groupID: groupA, body: "earlier")
        await store.preload([seeded])
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA).makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.body, "earlier")
    }

    func test_snapshots_emptyStream_yieldsEmptyArrayOnSubscribe() async {
        let store = InMemoryMessageStore()
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA).makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, [])
    }

    func test_insert_broadcastsNewSnapshot() async {
        let store = InMemoryMessageStore()
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA).makeAsyncIterator()
        _ = await iterator.next()  // initial empty

        let msg = makeMessage(groupID: groupA, body: "hello")
        let inserted = await repo.insert(msg)
        XCTAssertTrue(inserted)

        let next = await iterator.next()
        XCTAssertEqual(next?.count, 1)
        XCTAssertEqual(next?.first?.body, "hello")
    }

    func test_updateStatus_broadcastsStatusFlip() async {
        let store = InMemoryMessageStore()
        let msg = makeMessage(groupID: groupA, body: "wip", status: .pending)
        await store.preload([msg])
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA).makeAsyncIterator()
        _ = await iterator.next()  // initial: pending

        await repo.updateStatus(id: msg.id, status: .sent, groupID: groupA)

        let next = await iterator.next()
        XCTAssertEqual(next?.first?.status, .sent)
    }

    // MARK: - upgradeStatus (delivery / read receipts)

    func test_upgradeStatus_raisesAlongTheLadder() async {
        let store = InMemoryMessageStore()
        let msg = makeMessage(groupID: groupA, status: .sent)
        await store.preload([msg])
        let repo = MessageRepository(store: store)

        await repo.upgradeStatus(id: msg.id, to: .delivered, groupID: groupA)
        var stored = await repo.currentMessages(groupID: groupA)
        XCTAssertEqual(stored.first?.status, .delivered)

        await repo.upgradeStatus(id: msg.id, to: .read, groupID: groupA)
        stored = await repo.currentMessages(groupID: groupA)
        XCTAssertEqual(stored.first?.status, .read)
    }

    func test_upgradeStatus_neverDowngrades() async {
        let store = InMemoryMessageStore()
        let msg = makeMessage(groupID: groupA, status: .read)
        await store.preload([msg])
        let repo = MessageRepository(store: store)

        // A late delivered receipt arriving after read must not lower it.
        await repo.upgradeStatus(id: msg.id, to: .delivered, groupID: groupA)
        let stored = await repo.currentMessages(groupID: groupA)
        XCTAssertEqual(stored.first?.status, .read)
    }

    func test_upgradeStatus_ignoresIncomingRows() async {
        let store = InMemoryMessageStore()
        let incoming = ChatMessage(
            id: UUID(), groupID: groupA, ownerIdentityID: IdentityID(),
            senderBlsPubkeyHex: "11".repeated(48), body: "in",
            sentAt: Date(timeIntervalSince1970: 1),
            direction: .incoming, status: .received,
            replyToMessageID: nil, groupType: .tyranny
        )
        await store.preload([incoming])
        let repo = MessageRepository(store: store)

        await repo.upgradeStatus(id: incoming.id, to: .delivered, groupID: groupA)
        await repo.upgradeStatus(id: UUID(), to: .delivered, groupID: groupA)  // unknown id

        let stored = await repo.currentMessages(groupID: groupA)
        XCTAssertEqual(stored.first?.status, .received,
                       "receipts must never touch incoming rows or unknown ids")
    }

    func test_chatReceiptPayload_roundTrips() throws {
        let original = ChatReceiptPayload(
            version: 1, groupID: Data([0x01, 0x02, 0x03]),
            senderBlsPubkeyHex: "ab".repeated(48), kind: .read,
            messageIDs: [UUID(), UUID()]
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ChatReceiptPayload.self, from: data), original)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("message_ids"))
        XCTAssertTrue(json.contains("sender_bls_pubkey_hex"))
    }

    func test_delete_emptiesSnapshot() async {
        let store = InMemoryMessageStore()
        let msg = makeMessage(groupID: groupA)
        await store.preload([msg])
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA).makeAsyncIterator()
        _ = await iterator.next()

        await repo.delete(id: msg.id, groupID: groupA)
        let next = await iterator.next()
        XCTAssertEqual(next?.count, 0)
    }

    // MARK: - Per-group isolation

    func test_snapshots_insertIntoOtherGroup_doesNotEmit() async {
        let store = InMemoryMessageStore()
        let repo = MessageRepository(store: store)

        // Subscribe to group A.
        let snapshots = repo.snapshots(groupID: groupA)
        var iterator = snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial empty for A

        // Insert into group B — A's stream must not receive anything.
        _ = await repo.insert(makeMessage(groupID: groupB, body: "in B"))

        // Force an A-side mutation so the test has something to await
        // (we can't directly assert "no emission" without a timeout,
        // but back-to-back: A is silent through the B-insert and then
        // emits exactly the A-insert's snapshot).
        _ = await repo.insert(makeMessage(groupID: groupA, body: "in A"))
        let next = await iterator.next()
        XCTAssertEqual(next?.count, 1)
        XCTAssertEqual(next?.first?.body, "in A",
                       "group-A stream must skip the group-B insert and surface only the A-side row")
    }

    func test_snapshots_sortedBySentAtAscending() async {
        let store = InMemoryMessageStore()
        let older = makeMessage(
            groupID: groupA,
            body: "older",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = makeMessage(
            groupID: groupA,
            body: "newer",
            sentAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        await store.preload([newer, older])  // out of order on disk
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA).makeAsyncIterator()
        let snap = await iterator.next()
        XCTAssertEqual(snap?.map(\.body), ["older", "newer"])
    }

    // MARK: - Cascades

    func test_removeForGroup_clearsCacheAndEmitsEmpty() async {
        let store = InMemoryMessageStore()
        await store.preload([
            makeMessage(groupID: groupA, body: "a1"),
            makeMessage(groupID: groupA, body: "a2"),
        ])
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA).makeAsyncIterator()
        _ = await iterator.next()

        await repo.removeForGroup(groupA)
        let next = await iterator.next()
        XCTAssertEqual(next, [])
    }

    func test_removeForOwner_emptiesAllCachedGroups() async {
        let owner = IdentityID()
        let other = IdentityID()
        let store = InMemoryMessageStore()
        await store.preload([
            makeMessage(groupID: groupA, ownerIdentityID: owner, body: "a-owner"),
            makeMessage(groupID: groupB, ownerIdentityID: owner, body: "b-owner"),
            makeMessage(groupID: groupA, ownerIdentityID: other, body: "a-other"),
        ])
        let repo = MessageRepository(store: store)

        // Touch both groups so they enter the cache.
        var iterA = repo.snapshots(groupID: groupA).makeAsyncIterator()
        var iterB = repo.snapshots(groupID: groupB).makeAsyncIterator()
        _ = await iterA.next()
        _ = await iterB.next()

        await repo.removeForOwner(owner)

        // A still has the "other" identity's row; B is fully empty.
        let nextA = await iterA.next()
        let nextB = await iterB.next()
        XCTAssertEqual(nextA?.map(\.body), ["a-other"])
        XCTAssertEqual(nextB, [])
    }

    // MARK: - One-shot read

    func test_currentMessages_loadsFromStoreIfNotCached() async {
        let store = InMemoryMessageStore()
        await store.preload([makeMessage(groupID: groupA, body: "hello")])
        let repo = MessageRepository(store: store)

        let snap = await repo.currentMessages(groupID: groupA)
        XCTAssertEqual(snap.map(\.body), ["hello"])
    }

    // MARK: - Helpers

    private func makeMessage(
        id: UUID = UUID(),
        groupID: String,
        ownerIdentityID: IdentityID = IdentityID(),
        body: String = "hi",
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        status: MessageStatus = .sent
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            senderBlsPubkeyHex: "11".repeated(48),
            body: body,
            sentAt: sentAt,
            direction: .outgoing,
            status: status,
            replyToMessageID: nil,
            groupType: .tyranny
        )
    }
}

/// Reusable in-memory fake. Mirrors `InMemoryGroupStore` from the
/// `GroupRepositoryTests` file; kept private here so the two test
/// files stay independent.
private actor InMemoryMessageStore: MessageStore {
    private var rows: [UUID: ChatMessage] = [:]

    func preload(_ messages: [ChatMessage]) {
        for msg in messages { rows[msg.id] = msg }
    }

    func list(groupID: String) -> [ChatMessage] {
        rows.values
            .filter { $0.groupID == groupID }
            .sorted { $0.sentAt < $1.sentAt }
    }

    @discardableResult
    func insertOrUpdate(_ message: ChatMessage) -> Bool {
        let isNew = rows[message.id] == nil
        rows[message.id] = message
        return isNew
    }

    func updateStatus(id: UUID, status: MessageStatus, failureReason: SendFailureReason?) {
        guard let existing = rows[id] else { return }
        rows[id] = ChatMessage(
            id: existing.id,
            groupID: existing.groupID,
            ownerIdentityID: existing.ownerIdentityID,
            senderBlsPubkeyHex: existing.senderBlsPubkeyHex,
            body: existing.body,
            sentAt: existing.sentAt,
            direction: existing.direction,
            status: status,
            replyToMessageID: existing.replyToMessageID,
            groupType: existing.groupType,
            failureReason: failureReason
        )
    }

    func delete(id: UUID) {
        rows.removeValue(forKey: id)
    }

    func deleteGroup(groupID: String) {
        rows = rows.filter { $0.value.groupID != groupID }
    }

    func deleteOwner(_ ownerIDString: String) {
        rows = rows.filter { $0.value.ownerIdentityID.rawValue.uuidString != ownerIDString }
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
