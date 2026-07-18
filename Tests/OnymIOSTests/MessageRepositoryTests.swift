import XCTest
@testable import OnymIOS

/// Reactive-surface tests for `MessageRepository`. Backed by an
/// in-memory `MessageStore` fake — same pattern as
/// `GroupRepositoryTests`. Threads are keyed by `(groupID, owner)`, so
/// every read/mutation names the owning identity.
final class MessageRepositoryTests: XCTestCase {

    private let groupA = "aa".repeated(32)
    private let groupB = "bb".repeated(32)

    // MARK: - snapshots emission

    func test_snapshots_replaysCurrentOnSubscribe() async {
        let store = InMemoryMessageStore()
        let seeded = makeMessage(groupID: groupA, body: "earlier")
        await store.preload([seeded])
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.body, "earlier")
    }

    func test_snapshots_emptyStream_yieldsEmptyArrayOnSubscribe() async {
        let store = InMemoryMessageStore()
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, [])
    }

    func test_insert_broadcastsNewSnapshot() async {
        let store = InMemoryMessageStore()
        let repo = MessageRepository(store: store)

        var iterator = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
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

        var iterator = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
        _ = await iterator.next()  // initial: pending

        await repo.updateStatus(id: msg.id, status: .sent, groupID: groupA, owner: kOwnerA)

        let next = await iterator.next()
        XCTAssertEqual(next?.first?.status, .sent)
    }

    // MARK: - upgradeStatus (delivery / read receipts)

    func test_upgradeStatus_raisesAlongTheLadder() async {
        let store = InMemoryMessageStore()
        let msg = makeMessage(groupID: groupA, status: .sent)
        await store.preload([msg])
        let repo = MessageRepository(store: store)

        await repo.upgradeStatus(id: msg.id, to: .delivered, groupID: groupA, owner: kOwnerA)
        var stored = await repo.currentMessages(groupID: groupA, owner: kOwnerA)
        XCTAssertEqual(stored.first?.status, .delivered)

        await repo.upgradeStatus(id: msg.id, to: .read, groupID: groupA, owner: kOwnerA)
        stored = await repo.currentMessages(groupID: groupA, owner: kOwnerA)
        XCTAssertEqual(stored.first?.status, .read)
    }

    func test_upgradeStatus_neverDowngrades() async {
        let store = InMemoryMessageStore()
        let msg = makeMessage(groupID: groupA, status: .read)
        await store.preload([msg])
        let repo = MessageRepository(store: store)

        // A late delivered receipt arriving after read must not lower it.
        await repo.upgradeStatus(id: msg.id, to: .delivered, groupID: groupA, owner: kOwnerA)
        let stored = await repo.currentMessages(groupID: groupA, owner: kOwnerA)
        XCTAssertEqual(stored.first?.status, .read)
    }

    func test_upgradeStatus_ignoresIncomingRows() async {
        let store = InMemoryMessageStore()
        let incoming = ChatMessage(
            id: UUID(), groupID: groupA, ownerIdentityID: kOwnerA,
            senderBlsPubkeyHex: "11".repeated(48), body: "in",
            sentAt: Date(timeIntervalSince1970: 1),
            direction: .incoming, status: .received,
            replyToMessageID: nil, groupType: .tyranny
        )
        await store.preload([incoming])
        let repo = MessageRepository(store: store)

        await repo.upgradeStatus(id: incoming.id, to: .delivered, groupID: groupA, owner: kOwnerA)
        await repo.upgradeStatus(id: UUID(), to: .delivered, groupID: groupA, owner: kOwnerA)  // unknown id

        let stored = await repo.currentMessages(groupID: groupA, owner: kOwnerA)
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

        var iterator = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
        _ = await iterator.next()

        await repo.delete(id: msg.id, groupID: groupA, owner: kOwnerA)
        let next = await iterator.next()
        XCTAssertEqual(next?.count, 0)
    }

    // MARK: - Per-thread isolation

    func test_snapshots_insertIntoOtherGroup_doesNotEmit() async {
        let store = InMemoryMessageStore()
        let repo = MessageRepository(store: store)

        // Subscribe to group A.
        let snapshots = repo.snapshots(groupID: groupA, owner: kOwnerA)
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

    /// Two local identities, same group id: each owner's stream shows
    /// only its own rows. This is the message-side counterpart of the
    /// group "last invited identity wins" fix — before the composite
    /// `(id, owner)` key the second arrival stole the first's row.
    func test_snapshots_sameGroupTwoOwners_areIsolated() async {
        let store = InMemoryMessageStore()
        let owner2 = IdentityID()
        await store.preload([
            makeMessage(groupID: groupA, ownerIdentityID: kOwnerA, body: "mine"),
            makeMessage(groupID: groupA, ownerIdentityID: owner2, body: "theirs"),
        ])
        let repo = MessageRepository(store: store)

        var iterA = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
        var iter2 = repo.snapshots(groupID: groupA, owner: owner2).makeAsyncIterator()
        let a = await iterA.next()
        let b = await iter2.next()
        XCTAssertEqual(a?.map(\.body), ["mine"])
        XCTAssertEqual(b?.map(\.body), ["theirs"])
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

        var iterator = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
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

        var iterator = repo.snapshots(groupID: groupA, owner: kOwnerA).makeAsyncIterator()
        _ = await iterator.next()

        await repo.removeForGroup(groupA, owner: kOwnerA)
        let next = await iterator.next()
        XCTAssertEqual(next, [])
    }

    func test_removeForGroup_isScopedToOwner() async {
        let store = InMemoryMessageStore()
        let owner2 = IdentityID()
        await store.preload([
            makeMessage(groupID: groupA, ownerIdentityID: kOwnerA, body: "mine"),
            makeMessage(groupID: groupA, ownerIdentityID: owner2, body: "theirs"),
        ])
        let repo = MessageRepository(store: store)

        await repo.removeForGroup(groupA, owner: kOwnerA)

        let mine = await repo.currentMessages(groupID: groupA, owner: kOwnerA)
        let theirs = await repo.currentMessages(groupID: groupA, owner: owner2)
        XCTAssertEqual(mine, [])
        XCTAssertEqual(theirs.map(\.body), ["theirs"],
                       "removing one identity's thread leaves the other's copy of the group intact")
    }

    func test_removeForOwner_emptiesThatIdentitysThreads() async {
        let owner = IdentityID()
        let other = IdentityID()
        let store = InMemoryMessageStore()
        await store.preload([
            makeMessage(groupID: groupA, ownerIdentityID: owner, body: "a-owner"),
            makeMessage(groupID: groupB, ownerIdentityID: owner, body: "b-owner"),
            makeMessage(groupID: groupA, ownerIdentityID: other, body: "a-other"),
        ])
        let repo = MessageRepository(store: store)

        // Touch all three threads so they enter the cache.
        var iterOwnerA = repo.snapshots(groupID: groupA, owner: owner).makeAsyncIterator()
        var iterOwnerB = repo.snapshots(groupID: groupB, owner: owner).makeAsyncIterator()
        var iterOtherA = repo.snapshots(groupID: groupA, owner: other).makeAsyncIterator()
        _ = await iterOwnerA.next()
        _ = await iterOwnerB.next()
        _ = await iterOtherA.next()

        await repo.removeForOwner(owner)

        // Both of `owner`'s threads drain; `other`'s row in group A stays.
        let drainedA = await iterOwnerA.next()
        let drainedB = await iterOwnerB.next()
        XCTAssertEqual(drainedA, [])
        XCTAssertEqual(drainedB, [])
        let otherA = await repo.currentMessages(groupID: groupA, owner: other)
        XCTAssertEqual(otherA.map(\.body), ["a-other"])
    }

    // MARK: - One-shot read

    func test_currentMessages_loadsFromStoreIfNotCached() async {
        let store = InMemoryMessageStore()
        await store.preload([makeMessage(groupID: groupA, body: "hello")])
        let repo = MessageRepository(store: store)

        let snap = await repo.currentMessages(groupID: groupA, owner: kOwnerA)
        XCTAssertEqual(snap.map(\.body), ["hello"])
    }

    // MARK: - Helpers

    private func makeMessage(
        id: UUID = UUID(),
        groupID: String,
        ownerIdentityID: IdentityID = kOwnerA,
        body: String = "hi",
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        status: MessageStatus = .sent,
        direction: MessageDirection = .outgoing
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            groupID: groupID,
            ownerIdentityID: ownerIdentityID,
            senderBlsPubkeyHex: "11".repeated(48),
            body: body,
            sentAt: sentAt,
            direction: direction,
            status: status,
            replyToMessageID: nil,
            groupType: .tyranny
        )
    }

    // MARK: - Chat-list aggregates

    func test_latestMessage_returnsMostRecentBySentAt() async {
        let store = InMemoryMessageStore()
        let old = makeMessage(groupID: groupA, body: "old",
                              sentAt: Date(timeIntervalSince1970: 1_000))
        let new = makeMessage(groupID: groupA, body: "new",
                              sentAt: Date(timeIntervalSince1970: 2_000))
        await store.preload([old, new])
        let repo = MessageRepository(store: store)

        let latest = await repo.latestMessage(groupID: groupA, owner: kOwnerA)
        XCTAssertEqual(latest?.body, "new")
        // A group with no messages has no latest.
        let none = await repo.latestMessage(groupID: "empty", owner: kOwnerA)
        XCTAssertNil(none)
    }

    func test_unreadCount_countsIncomingAfterMarker() async {
        let store = InMemoryMessageStore()
        let marker = Date(timeIntervalSince1970: 1_500)
        await store.preload([
            // Before the marker → read.
            makeMessage(groupID: groupA, body: "seen",
                        sentAt: Date(timeIntervalSince1970: 1_000), direction: .incoming),
            // After the marker, incoming → unread (x2).
            makeMessage(groupID: groupA, body: "u1",
                        sentAt: Date(timeIntervalSince1970: 2_000), direction: .incoming),
            makeMessage(groupID: groupA, body: "u2",
                        sentAt: Date(timeIntervalSince1970: 3_000), direction: .incoming),
            // After the marker but outgoing → never unread.
            makeMessage(groupID: groupA, body: "mine",
                        sentAt: Date(timeIntervalSince1970: 4_000), direction: .outgoing),
        ])
        let repo = MessageRepository(store: store)

        let unread = await repo.unreadCount(groupID: groupA, owner: kOwnerA, since: marker)
        XCTAssertEqual(unread, 2)
        // distantPast counts every incoming message.
        let all = await repo.unreadCount(groupID: groupA, owner: kOwnerA, since: .distantPast)
        XCTAssertEqual(all, 3)
    }
}

/// Shared default owner for the single-identity tests above. File-scope
/// so `makeMessage`'s default argument can reference it (default args
/// can't touch instance state).
private let kOwnerA = IdentityID()

/// Reusable in-memory fake. Mirrors `InMemoryGroupStore` from the
/// `GroupRepositoryTests` file; kept private here so the two test
/// files stay independent. Keyed by the composite `(id, owner)` so it
/// can hold two identities' copies of the same wire message.
private actor InMemoryMessageStore: MessageStore {
    private struct Key: Hashable { let id: UUID; let owner: IdentityID }
    private var rows: [Key: ChatMessage] = [:]

    func preload(_ messages: [ChatMessage]) {
        for msg in messages { rows[Key(id: msg.id, owner: msg.ownerIdentityID)] = msg }
    }

    func list(groupID: String, ownerIDString: String) -> [ChatMessage] {
        rows.values
            .filter { $0.groupID == groupID && $0.ownerIdentityID.rawValue.uuidString == ownerIDString }
            .sorted { $0.sentAt < $1.sentAt }
    }

    func latestMessage(groupID: String, ownerIDString: String) -> ChatMessage? {
        rows.values
            .filter { $0.groupID == groupID && $0.ownerIdentityID.rawValue.uuidString == ownerIDString }
            .max { $0.sentAt < $1.sentAt }
    }

    func unreadCount(groupID: String, ownerIDString: String, since: Date) -> Int {
        rows.values.filter {
            $0.groupID == groupID
                && $0.ownerIdentityID.rawValue.uuidString == ownerIDString
                && $0.direction == .incoming
                && $0.sentAt > since
        }.count
    }

    func search(ownerIDString: String, query: String, limit: Int) -> [ChatMessage] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return rows.values
            .filter {
                $0.ownerIdentityID.rawValue.uuidString == ownerIDString
                    && $0.body.lowercased().contains(needle)
            }
            .sorted { $0.sentAt > $1.sentAt }
            .prefix(limit)
            .map { $0 }
    }

    @discardableResult
    func insertOrUpdate(_ message: ChatMessage) -> Bool {
        let key = Key(id: message.id, owner: message.ownerIdentityID)
        let isNew = rows[key] == nil
        rows[key] = message
        return isNew
    }

    func updateStatus(id: UUID, ownerIDString: String, status: MessageStatus, failureReason: SendFailureReason?) {
        guard let owner = IdentityID(ownerIDString) else { return }
        let key = Key(id: id, owner: owner)
        guard let existing = rows[key] else { return }
        rows[key] = ChatMessage(
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

    func delete(id: UUID, ownerIDString: String) {
        guard let owner = IdentityID(ownerIDString) else { return }
        rows.removeValue(forKey: Key(id: id, owner: owner))
    }

    func deleteGroup(groupID: String, ownerIDString: String) {
        rows = rows.filter {
            !($0.value.groupID == groupID && $0.value.ownerIdentityID.rawValue.uuidString == ownerIDString)
        }
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
