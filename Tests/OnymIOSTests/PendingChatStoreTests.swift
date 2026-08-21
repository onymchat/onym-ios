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

    func test_deleteForIDs_dropsOnlyTheMaterializedOnes() async {
        let store = SwiftDataPendingChatStore.inMemory()
        let landed = makeChat(group: 0x11, owner: owner)
        let waiting = makeChat(group: 0x22, owner: owner)
        await store.insert(landed)
        await store.insert(waiting)

        await store.deleteForIDs([landed.id])

        let rows = await store.list()
        XCTAssertEqual(rows.map(\.groupIDHex), [waiting.groupIDHex])
    }

    func test_deleteForIDs_leavesTheOtherIdentitysRowForTheSameGroup() async {
        // Deleting by group alone took the other identity's waiting room
        // with it the moment this one got in — the same composite-key
        // mistake `PersistedGroup` documents one layer down.
        let store = SwiftDataPendingChatStore.inMemory()
        let mine = makeChat(group: 0x11, owner: owner)
        let theirs = makeChat(group: 0x11, owner: other)
        await store.insert(mine)
        await store.insert(theirs)

        await store.deleteForIDs([mine.id])

        let rows = await store.list()
        XCTAssertEqual(rows.map(\.ownerIdentityID), [other])
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

    func test_rowsSurviveAFreshContext() async {
        // Not a relaunch — `inMemory()` never touches disk and the
        // container outlives both stores. What this shows is that the
        // write reached the container's store rather than sitting in the
        // context that made it, which is the half of durability a test
        // can check here. The other half is why the production store is
        // SQLite: a link join is replayed by nothing, so a force-quit
        // would otherwise leave someone waiting on a request their
        // device has no record of.
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

    // MARK: - Both conformers, one contract

    func test_swiftDataStore_honoursTheContract() async throws {
        try await assertHonoursContract(SwiftDataPendingChatStore.inMemory())
    }

    func test_inMemoryStore_honoursTheContract() async throws {
        // The fallback for a device whose store won't open has to behave
        // the same, or a failed open changes what the app does rather
        // than only where it keeps its rows. Hand-checking three of the
        // six methods let `delete`, `deleteOwner` and ordering diverge in
        // silence, so both conformers run the same exercise.
        try await assertHonoursContract(InMemoryPendingChatStore())
    }

    /// Every method on `PendingChatStore`, in one pass.
    private func assertHonoursContract(
        _ store: any PendingChatStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let old = makeChat(group: 0x11, owner: owner, receivedAt: Date(timeIntervalSince1970: 100))
        let new = makeChat(group: 0x22, owner: owner, receivedAt: Date(timeIntervalSince1970: 200))
        let theirs = makeChat(group: 0x33, owner: other)

        let inserted = await store.insert(old)
        let duplicate = await store.insert(old)
        XCTAssertEqual(inserted, .inserted, file: file, line: line)
        XCTAssertEqual(duplicate, .alreadyPresent, file: file, line: line)
        await store.insert(new)
        await store.insert(theirs)

        // Newest first.
        let listed = await store.list()
        XCTAssertEqual(
            listed.map(\.id),
            [theirs, new, old].sorted { $0.receivedAt > $1.receivedAt }.map(\.id),
            file: file, line: line
        )

        await store.setStatus(id: old.id, status: .failed(reason: "relay rejected"))
        let afterStatus = await store.list().first { $0.id == old.id }
        XCTAssertEqual(afterStatus?.status, .failed(reason: "relay rejected"), file: file, line: line)
        // A row that isn't there absorbs the write rather than creating one.
        await store.setStatus(id: "nobody:home", status: .requested)
        let afterGhost = await store.list()
        XCTAssertEqual(afterGhost.count, 3, file: file, line: line)

        await store.delete(id: old.id)
        let afterDelete = await store.list()
        XCTAssertEqual(Set(afterDelete.map(\.id)), [new.id, theirs.id], file: file, line: line)

        await store.deleteForIDs([new.id])
        let afterSweep = await store.list()
        XCTAssertEqual(afterSweep.map(\.id), [theirs.id], file: file, line: line)

        await store.deleteOwner(other.rawValue.uuidString)
        let afterCascade = await store.list()
        XCTAssertTrue(afterCascade.isEmpty, file: file, line: line)
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
