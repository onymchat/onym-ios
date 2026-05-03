import XCTest
@testable import OnymIOS

/// Reactive-surface tests for `GroupRepository`. Backed by an in-memory
/// `GroupStore` fake. Every test pre-selects an identity via the repo's
/// constructor so the filter doesn't drop the seeded groups.
final class GroupRepositoryTests: XCTestCase {

    /// One owner shared across single-identity tests so the repo's
    /// `currentIdentityID` filter doesn't accidentally hide test data.
    private let ownerA = IdentityID()
    private let ownerB = IdentityID()

    func test_snapshots_replaysCurrentOnSubscribe() async throws {
        let store = InMemoryGroupStore()
        let group = makeGroup(id: "aa".repeated(32), name: "Family", owner: ownerA)
        await store.preload([group])
        let repo = GroupRepository(store: store, currentIdentityID: ownerA)

        var iterator = repo.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.id, group.id)
    }

    func test_insert_broadcastsNewSnapshot() async throws {
        let store = InMemoryGroupStore()
        let repo = GroupRepository(store: store, currentIdentityID: ownerA)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial empty snapshot

        let group = makeGroup(id: "bb".repeated(32), name: "Friends", owner: ownerA)
        let inserted = await repo.insert(group)
        XCTAssertTrue(inserted)

        let next = await iterator.next()
        XCTAssertEqual(next?.count, 1)
        XCTAssertEqual(next?.first?.name, "Friends")
    }

    func test_markPublished_broadcastsUpdatedSnapshot() async throws {
        let store = InMemoryGroupStore()
        let group = makeGroup(id: "cc".repeated(32), name: "G", owner: ownerA)
        await store.preload([group])
        let repo = GroupRepository(store: store, currentIdentityID: ownerA)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()

        let onchainCommitment = Data(repeating: 0x42, count: 32)
        await repo.markPublished(id: group.id, commitment: onchainCommitment)

        let next = await iterator.next()
        XCTAssertEqual(next?.first?.isPublishedOnChain, true)
        XCTAssertEqual(next?.first?.commitment, onchainCommitment)
    }

    func test_delete_emptiesSnapshot() async throws {
        let store = InMemoryGroupStore()
        let group = makeGroup(id: "dd".repeated(32), name: "G", owner: ownerA)
        await store.preload([group])
        let repo = GroupRepository(store: store, currentIdentityID: ownerA)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()

        await repo.delete(id: group.id)
        let next = await iterator.next()
        XCTAssertEqual(next?.count, 0)
    }

    // MARK: - Multi-identity filter

    func test_snapshots_onlyContainCurrentOwnerGroups() async throws {
        let store = InMemoryGroupStore()
        await store.preload([
            makeGroup(id: "aa".repeated(32), name: "A", owner: ownerA),
            makeGroup(id: "bb".repeated(32), name: "B1", owner: ownerB),
            makeGroup(id: "cc".repeated(32), name: "B2", owner: ownerB),
        ])
        let repo = GroupRepository(store: store, currentIdentityID: ownerA)

        var iterator = repo.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.map(\.name), ["A"],
                       "subscriber must only see groups owned by the active identity")
    }

    func test_setCurrentIdentity_reEmitsFilteredSnapshot() async throws {
        let store = InMemoryGroupStore()
        await store.preload([
            makeGroup(id: "aa".repeated(32), name: "A", owner: ownerA),
            makeGroup(id: "bb".repeated(32), name: "B", owner: ownerB),
        ])
        let repo = GroupRepository(store: store, currentIdentityID: ownerA)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // owner A's view

        await repo.setCurrentIdentity(ownerB)
        let next = await iterator.next()
        XCTAssertEqual(next?.map(\.name), ["B"],
                       "switching identity re-emits with the new filter applied")
    }

    func test_setCurrentIdentity_nilEmitsEmptySnapshot() async throws {
        let store = InMemoryGroupStore()
        await store.preload([makeGroup(id: "aa".repeated(32), name: "A", owner: ownerA)])
        let repo = GroupRepository(store: store, currentIdentityID: ownerA)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()

        await repo.setCurrentIdentity(nil)
        let next = await iterator.next()
        XCTAssertEqual(next, [],
                       "nil current identity → empty snapshot (no orphaned groups visible)")
    }

    func test_removeForOwner_dropsThatIdentitysGroups() async throws {
        let store = InMemoryGroupStore()
        await store.preload([
            makeGroup(id: "aa".repeated(32), name: "A", owner: ownerA),
            makeGroup(id: "bb".repeated(32), name: "B1", owner: ownerB),
            makeGroup(id: "cc".repeated(32), name: "B2", owner: ownerB),
        ])
        let repo = GroupRepository(store: store, currentIdentityID: ownerB)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial: 2 groups for B

        await repo.removeForOwner(ownerB)
        let next = await iterator.next()
        XCTAssertEqual(next, [], "removeForOwner wipes the owner's groups from the store")

        // Switching to A still surfaces A's group — only B's were dropped.
        await repo.setCurrentIdentity(ownerA)
        let stillA = await iterator.next()
        XCTAssertEqual(stillA?.map(\.name), ["A"])
    }

    // MARK: - Helpers

    private func makeGroup(id: String, name: String, owner: IdentityID) -> ChatGroup {
        ChatGroup(
            id: id,
            ownerIdentityID: owner,
            name: name,
            groupSecret: Data(repeating: 0x33, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            members: [],
            epoch: 0,
            salt: Data(repeating: 0x44, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            isPublishedOnChain: false
        )
    }
}

/// Reusable in-memory fake; lives next to the test that uses it.
private actor InMemoryGroupStore: GroupStore {
    private var rows: [String: ChatGroup] = [:]

    func preload(_ groups: [ChatGroup]) {
        for group in groups { rows[group.id] = group }
    }

    func list() -> [ChatGroup] {
        rows.values.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func insertOrUpdate(_ group: ChatGroup) -> Bool {
        let isNew = rows[group.id] == nil
        rows[group.id] = group
        return isNew
    }

    func markPublished(id: String, commitment: Data?) {
        guard var existing = rows[id] else { return }
        existing.isPublishedOnChain = true
        if let commitment {
            existing.commitment = commitment
        }
        rows[id] = existing
    }

    func delete(id: String) {
        rows.removeValue(forKey: id)
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
