import XCTest
@testable import OnymIOS

/// Reactive-surface tests for `GroupRepository`. Backed by an in-memory
/// `GroupStore` fake so the SwiftData layer doesn't pull in the
/// Keychain-dependent `StorageEncryption` here — that's covered by
/// `SwiftDataGroupStoreTests`. Mirrors `IncomingInvitationsRepositoryTests`.
final class GroupRepositoryTests: XCTestCase {

    func test_snapshots_replaysCurrentOnSubscribe() async throws {
        let store = InMemoryGroupStore()
        let group = makeGroup(id: "aa".repeated(32), name: "Family")
        await store.preload([group])
        let repo = GroupRepository(store: store)

        var iterator = repo.snapshots.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.first?.id, group.id)
    }

    func test_insert_broadcastsNewSnapshot() async throws {
        let store = InMemoryGroupStore()
        let repo = GroupRepository(store: store)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()  // initial empty snapshot

        let group = makeGroup(id: "bb".repeated(32), name: "Friends")
        let inserted = await repo.insert(group)
        XCTAssertTrue(inserted)

        let next = await iterator.next()
        XCTAssertEqual(next?.count, 1)
        XCTAssertEqual(next?.first?.name, "Friends")
    }

    func test_markPublished_broadcastsUpdatedSnapshot() async throws {
        let store = InMemoryGroupStore()
        let group = makeGroup(id: "cc".repeated(32), name: "G")
        await store.preload([group])
        let repo = GroupRepository(store: store)

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
        let group = makeGroup(id: "dd".repeated(32), name: "G")
        await store.preload([group])
        let repo = GroupRepository(store: store)

        var iterator = repo.snapshots.makeAsyncIterator()
        _ = await iterator.next()

        await repo.delete(id: group.id)
        let next = await iterator.next()
        XCTAssertEqual(next?.count, 0)
    }

    // MARK: - Helpers

    private func makeGroup(id: String, name: String) -> ChatGroup {
        ChatGroup(
            id: id,
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

/// Reusable in-memory fake; lives next to the test that uses it
/// because PR-B has only one consumer. Promote to `Tests/Support/`
/// when PR-C's interactor tests grow a second one.
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
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
