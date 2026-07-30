import Security
import XCTest
@testable import OnymIOS

/// TTL + GC behavior of the production intro-key store. These paths
/// hide/destroy intro PRIVATE keys, so they get coverage in the PR
/// that introduces them rather than the stack-final test PR. Hits the
/// real Keychain under a per-test namespace, same rationale as
/// `IdentityKeychainStoreTests`.
final class KeychainIntroKeyStoreTests: XCTestCase {
    private var namespace: String!
    private var store: KeychainIntroKeyStore!
    private let ownerA = IdentityID()
    private let ownerB = IdentityID()

    override func setUp() {
        super.setUp()
        namespace = "tests-\(UUID().uuidString)"
        store = KeychainIntroKeyStore(testNamespace: namespace)
    }

    override func tearDown() async throws {
        await store.wipeAll()
        store = nil
        try await super.tearDown()
    }

    // MARK: - TTL

    func test_expiredEntry_invisibleToReads() async {
        await store.save(makeEntry(owner: ownerA, age: KeychainIntroKeyStore.entryTTL + 60))
        let fresh = makeEntry(owner: ownerA)
        await store.save(fresh)

        let listed = await store.listForOwner(ownerA)
        XCTAssertEqual(listed.map(\.introPublicKey), [fresh.introPublicKey],
                       "entries past the 24h TTL must be invisible to listForOwner")
    }

    func test_expiredEntry_compactsOutOfBlobOnFirstRead() async {
        let fresh = makeEntry(owner: ownerA)
        await store.save(fresh)
        await store.save(makeEntry(owner: ownerB, age: KeychainIntroKeyStore.entryTTL + 60))
        // No subscribers → save's publish no-ops without reading, so
        // the expired row really is at rest now.
        XCTAssertEqual(rawEntryCount(), 2)

        _ = await store.listForOwner(ownerA)

        XCTAssertEqual(rawEntryCount(), 1,
                       "the read that first sees an expired intro privkey must rewrite the blob without it")
    }

    func test_expiredEntry_streamSnapshotExcludesIt() async {
        await store.save(makeEntry(owner: ownerB, age: KeychainIntroKeyStore.entryTTL + 60))

        var iterator = store.entriesStream(forOwner: ownerB).makeAsyncIterator()
        let snapshot = await iterator.next()

        XCTAssertEqual(snapshot, [],
                       "the intro pump must never see an expired entry's inbox")
        XCTAssertEqual(rawEntryCount(), 0,
                       "subscribing triggered the read → the expired privkey is gone at rest too")
    }

    // MARK: - pruneOwners

    func test_pruneOwners_dropsOrphanedOwnersOnly() async {
        let kept = makeEntry(owner: ownerA)
        await store.save(kept)
        await store.save(makeEntry(owner: ownerB))

        let removed = await store.pruneOwners(keeping: [ownerA])

        XCTAssertEqual(removed, 1)
        let aEntries = await store.listForOwner(ownerA)
        let bEntries = await store.listForOwner(ownerB)
        XCTAssertEqual(aEntries.map(\.introPublicKey), [kept.introPublicKey],
                       "a kept owner's entries survive the prune")
        XCTAssertEqual(bEntries, [], "an orphaned owner's entries are gone")
    }

    func test_pruneOwners_publishesEmptySnapshotToOrphanedOwnersStream() async {
        let orphaned = makeEntry(owner: ownerB)
        await store.save(orphaned)
        var iterator = store.entriesStream(forOwner: ownerB).makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.introPublicKey), [orphaned.introPublicKey])

        await store.pruneOwners(keeping: [ownerA])

        let afterPrune = await iterator.next()
        XCTAssertEqual(afterPrune, [],
                       "the pump must be told to drop the pruned owner's inbox subscriptions")
    }

    func test_pruneOwners_noOrphans_isNoOp() async {
        await store.save(makeEntry(owner: ownerA))
        let removed = await store.pruneOwners(keeping: [ownerA])
        XCTAssertEqual(removed, 0)
    }

    // MARK: - Helpers

    private func makeEntry(owner: IdentityID, age: TimeInterval = 0) -> IntroKeyEntry {
        IntroKeyEntry(
            introPublicKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            introPrivateKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            ownerIdentityID: owner,
            groupId: Data(repeating: 7, count: 32),
            createdAt: Date().addingTimeInterval(-age)
        )
    }

    /// Reads the store's blob straight out of the Keychain and counts
    /// its rows — the only way to assert compaction *at rest* rather
    /// than just read-side filtering.
    private func rawEntryCount() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(KeychainIntroKeyStore.serviceDefault).\(namespace!)",
            kSecAttrAccount as String: KeychainIntroKeyStore.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [Any]
        else { return 0 }
        return entries.count
    }
}
