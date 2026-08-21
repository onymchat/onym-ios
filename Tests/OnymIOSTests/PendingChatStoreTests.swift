import XCTest
@testable import OnymInbox
@testable import OnymIdentity

/// The store under the chats-list rows for a chat that hasn't opened
/// yet. What matters here is dedup (a relay replays an offer on every
/// reconnect), status transitions (asked / failed), and that the rows
/// survive the relaunch the old in-memory store did not.
final class PendingChatStoreTests: XCTestCase {

    private let owner = IdentityID()
    private let other = IdentityID()

    // MARK: - Dedup

    func test_insert_isKeyedByGroupAndOwner_notByDelivery() async {
        let store = SwiftDataPendingChatStore.inMemory()
        let first = await store.insert(makeChat(group: 0x11, owner: owner))
        // Same group, same identity, later delivery: the same waiting
        // room, not a second one.
        let second = await store.insert(
            makeChat(group: 0x11, owner: owner, receivedAt: Date().addingTimeInterval(60))
        )

        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(second, .alreadyPresent)
        let rows = await store.list()
        XCTAssertEqual(rows.count, 1)
    }

    func test_insert_keepsOneRowPerIdentityForTheSameGroup() async {
        // Two identities on one device can be invited to the same chat.
        // Collapsing them would hide one person's invitation behind the
        // other's, which is the bug `PersistedGroup`'s composite key
        // exists to prevent one layer down.
        let store = SwiftDataPendingChatStore.inMemory()
        await store.insert(makeChat(group: 0x11, owner: owner))
        await store.insert(makeChat(group: 0x11, owner: other))

        let rows = await store.list()
        XCTAssertEqual(rows.count, 2)
    }

    func test_replayedOffer_doesNotResetAnAcceptedRow() async {
        // The failure this key exists to prevent: the relay re-delivers
        // the offer, and a chat the user already accepted goes back to
        // asking them to accept it.
        let store = SwiftDataPendingChatStore.inMemory()
        let chat = makeChat(group: 0x11, owner: owner)
        await store.insert(chat)
        await store.setStatus(id: chat.id, status: .requested)

        await store.insert(chat)

        let rows = await store.list()
        XCTAssertEqual(rows.first?.status, .requested)
    }

    // MARK: - Status

    func test_setStatus_carriesTheFailureReason() async {
        let store = SwiftDataPendingChatStore.inMemory()
        let chat = makeChat(group: 0x11, owner: owner)
        await store.insert(chat)

        await store.setStatus(id: chat.id, status: .failed(reason: "relay rejected"))

        let rows = await store.list()
        XCTAssertEqual(rows.first?.status, .failed(reason: "relay rejected"))
    }

    func test_setStatus_onAMissingRowIsANoOp() async {
        // The ordinary race: the group materializes while a join request
        // is still in flight, so the row is gone by the time the send
        // reports back.
        let store = SwiftDataPendingChatStore.inMemory()
        await store.setStatus(id: "nobody:home", status: .requested)
        let rows = await store.list()
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Removal

    func test_deleteForGroups_dropsOnlyTheMaterializedOnes() async {
        let store = SwiftDataPendingChatStore.inMemory()
        let landed = makeChat(group: 0x11, owner: owner)
        let waiting = makeChat(group: 0x22, owner: owner)
        await store.insert(landed)
        await store.insert(waiting)

        await store.deleteForGroups(hexes: [landed.groupIDHex])

        let rows = await store.list()
        XCTAssertEqual(rows.map(\.groupIDHex), [waiting.groupIDHex])
    }

    func test_deleteOwner_cascadesForARemovedIdentity() async {
        let store = SwiftDataPendingChatStore.inMemory()
        await store.insert(makeChat(group: 0x11, owner: owner))
        await store.insert(makeChat(group: 0x22, owner: other))

        await store.deleteOwner(owner.rawValue.uuidString)

        let rows = await store.list()
        XCTAssertEqual(rows.map(\.ownerIdentityID), [other])
    }

    // MARK: - Durability + ordering

    func test_rowsSurviveAReopen() async {
        // The whole reason this store is on disk: a link join is
        // replayed by nothing, so a force-quit would otherwise leave
        // someone waiting on a request their device has no record of.
        let store = SwiftDataPendingChatStore.inMemory()
        let chat = makeChat(group: 0x11, owner: owner)
        await store.insert(chat)
        await store.setStatus(id: chat.id, status: .requested)

        let relaunched = await store.reopened()
        let rows = await relaunched.list()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, .requested)
        XCTAssertEqual(rows.first?.groupName, "Maple Garden")
        XCTAssertEqual(rows.first?.introPublicKey, Data(repeating: 0x44, count: 32))
    }

    func test_list_isNewestFirst() async {
        let store = SwiftDataPendingChatStore.inMemory()
        let old = makeChat(group: 0x11, owner: owner, receivedAt: Date(timeIntervalSince1970: 100))
        let new = makeChat(group: 0x22, owner: owner, receivedAt: Date(timeIntervalSince1970: 200))
        await store.insert(old)
        await store.insert(new)

        let rows = await store.list()
        XCTAssertEqual(rows.map(\.groupIDHex), [new.groupIDHex, old.groupIDHex])
    }

    func test_inMemoryStore_matchesTheOnDiskContract() async {
        // The fallback for a device whose store won't open has to behave
        // the same, or a failed open changes what the app does rather
        // than only where it keeps it.
        let store = InMemoryPendingChatStore()
        let chat = makeChat(group: 0x11, owner: owner)
        let first = await store.insert(chat)
        let second = await store.insert(chat)
        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(second, .alreadyPresent)

        await store.setStatus(id: chat.id, status: .requested)
        let requested = await store.list()
        XCTAssertEqual(requested.first?.status, .requested)

        await store.deleteForGroups(hexes: [chat.groupIDHex])
        let emptied = await store.list()
        XCTAssertTrue(emptied.isEmpty)
    }

    // MARK: - Helpers

    private func makeChat(
        group: UInt8,
        owner: IdentityID,
        receivedAt: Date = Date(),
        status: PendingChat.Status = .offered
    ) -> PendingChat {
        PendingChat(
            groupID: Data(repeating: group, count: 32),
            ownerIdentityID: owner,
            introPublicKey: Data(repeating: 0x44, count: 32),
            groupName: "Maple Garden",
            inviterAlias: "Alice",
            invitationMessage: "come in",
            receivedAt: receivedAt,
            status: status
        )
    }
}
