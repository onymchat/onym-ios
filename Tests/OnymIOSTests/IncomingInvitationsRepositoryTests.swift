import XCTest
@testable import OnymIOS

/// Repository contract on top of the in-memory store fake — fast,
/// focused on the reactive surface (snapshots emit current value on
/// subscribe + a fresh value after every successful mutation), the
/// mutator semantics, dedup behaviour, and post-#58 the per-identity
/// filter + `removeForOwner` hook.
///
/// CRUD against the real SwiftData backend lives in
/// `SwiftDataInvitationStoreTests`; the two tests together exercise
/// the same seam contract from both sides.
final class IncomingInvitationsRepositoryTests: XCTestCase {
    private var store: InMemoryInvitationStore!
    private var repository: IncomingInvitationsRepository!

    /// One owner shared across single-identity tests so the repo's
    /// `currentIdentityID` filter doesn't accidentally hide test data.
    private let ownerA = IdentityID()
    private let ownerB = IdentityID()

    override func setUp() {
        super.setUp()
        store = InMemoryInvitationStore()
        repository = IncomingInvitationsRepository(
            store: store,
            currentIdentityID: ownerA
        )
    }

    override func tearDown() {
        store = nil
        repository = nil
        super.tearDown()
    }

    // MARK: - recordIncoming

    func test_recordIncoming_savesViaStore() async {
        let inserted = await repository.recordIncoming(
            id: "evt-1",
            ownerIdentityID: ownerA,
            payload: Data("hello".utf8),
            receivedAt: Date()
        )
        XCTAssertTrue(inserted)
        let stored = await store.list()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].id, "evt-1")
        XCTAssertEqual(stored[0].ownerIdentityID, ownerA)
        XCTAssertEqual(stored[0].status, .pending,
                       "recordIncoming always lands as pending")
    }

    func test_recordIncoming_isIdempotentById() async {
        let now = Date()
        let first = await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: now)
        let second = await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: now)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let stored = await store.list()
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: - updateStatus + delete

    func test_updateStatus_changesStoredStatus() async {
        await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())
        await repository.updateStatus(id: "evt-1", status: .accepted)
        let stored = await store.list()
        XCTAssertEqual(stored[0].status, .accepted)
    }

    func test_delete_removesFromStore() async {
        await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())
        await repository.delete(id: "evt-1")
        let stored = await store.list()
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: - snapshots

    func test_snapshots_emitsCurrentValueOnSubscribe() async throws {
        await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())

        let stream = repository.snapshots
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.id, "evt-1")
    }

    func test_snapshots_emitsFreshValueAfterMutation() async throws {
        let stream = repository.snapshots
        var iterator = stream.makeAsyncIterator()
        // Initial empty snapshot
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 0)

        await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())

        let afterInsert = await iterator.next()
        XCTAssertEqual(afterInsert?.count, 1)
        XCTAssertEqual(afterInsert?.first?.id, "evt-1")
    }

    func test_snapshots_skipsDedupNoOp() async throws {
        await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())

        let stream = repository.snapshots
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.count, 1)

        // Second recordIncoming with same id is a dedup no-op — no
        // snapshot push, otherwise subscribers would see redundant
        // identical lists.
        let inserted = await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())
        XCTAssertFalse(inserted)

        // Trigger a real mutation to advance the iterator past the
        // would-be dedup tick — if the dedup had pushed, this next
        // value would be a stale duplicate of `initial`.
        await repository.recordIncoming(id: "evt-2", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())
        let afterRealInsert = await iterator.next()
        XCTAssertEqual(afterRealInsert?.count, 2,
                       "second snapshot must reflect evt-2, not a redundant dedup tick")
    }

    func test_snapshots_emitsAfterStatusUpdate() async throws {
        await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())

        let stream = repository.snapshots
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()  // initial

        await repository.updateStatus(id: "evt-1", status: .accepted)

        let afterUpdate = await iterator.next()
        XCTAssertEqual(afterUpdate?.first?.status, .accepted)
    }

    func test_snapshots_emitsAfterDelete() async throws {
        await repository.recordIncoming(id: "evt-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())

        let stream = repository.snapshots
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()  // initial

        await repository.delete(id: "evt-1")

        let afterDelete = await iterator.next()
        XCTAssertEqual(afterDelete?.count, 0)
    }

    // MARK: - Multi-identity filter

    func test_snapshots_onlyContainCurrentOwnerInvitations() async throws {
        await repository.recordIncoming(id: "a-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())
        await repository.recordIncoming(id: "b-1", ownerIdentityID: ownerB, payload: Data(), receivedAt: Date())
        await repository.recordIncoming(id: "b-2", ownerIdentityID: ownerB, payload: Data(), receivedAt: Date())

        var iterator = repository.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.map(\.id), ["a-1"],
                       "subscriber only sees the active identity's invitations; B's are persisted but hidden")
        // Confirm the store actually has all three — only the view is filtered.
        let stored = await store.list()
        XCTAssertEqual(stored.count, 3,
                       "all three invitations stay on disk; switching identity surfaces B's later")
    }

    func test_setCurrentIdentity_reEmitsFilteredSnapshot() async throws {
        await repository.recordIncoming(id: "a-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())
        await repository.recordIncoming(id: "b-1", ownerIdentityID: ownerB, payload: Data(), receivedAt: Date())

        var iterator = repository.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // owner A's view

        await repository.setCurrentIdentity(ownerB)
        let next = await iterator.next()
        XCTAssertEqual(next?.map(\.id), ["b-1"],
                       "switching identity re-emits with the new filter applied — no invitations lost in the swap")
    }

    func test_removeForOwner_dropsThatIdentitysInvitations() async throws {
        await repository.recordIncoming(id: "a-1", ownerIdentityID: ownerA, payload: Data(), receivedAt: Date())
        await repository.recordIncoming(id: "b-1", ownerIdentityID: ownerB, payload: Data(), receivedAt: Date())
        await repository.recordIncoming(id: "b-2", ownerIdentityID: ownerB, payload: Data(), receivedAt: Date())
        await repository.setCurrentIdentity(ownerB)

        var iterator = repository.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial: 2 invitations for B

        await repository.removeForOwner(ownerB)
        let next = await iterator.next()
        XCTAssertEqual(next, [], "removeForOwner wipes the owner's invitations from the store")

        // Switching to A still surfaces A's invitation — only B's were dropped.
        await repository.setCurrentIdentity(ownerA)
        let stillA = await iterator.next()
        XCTAssertEqual(stillA?.map(\.id), ["a-1"])
    }
}
