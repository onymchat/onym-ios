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

    // MARK: - no expiry

    func test_oldEntry_staysVisibleAndAtRest() async {
        // Invite links do not expire. An entry minted long ago is as
        // usable as one minted a second ago; only `revoke` retires it.
        let ancient = makeEntry(owner: ownerA, age: 400 * 24 * 60 * 60)
        await store.save(ancient)
        let fresh = makeEntry(owner: ownerA)
        await store.save(fresh)

        let listed = await store.listForOwner(ownerA)
        XCTAssertEqual(Set(listed.map(\.introPublicKey)),
                       Set([ancient.introPublicKey, fresh.introPublicKey]))
        let foundAncient = await store.find(introPublicKey: ancient.introPublicKey)
        XCTAssertNotNil(foundAncient)
        XCTAssertEqual(rawEntryCount(), 2, "reads must not silently drop rows")
    }

    func test_revokedEntry_disappearsFromReadsAndFromTheBlob() async {
        let doomed = makeEntry(owner: ownerA, age: 400 * 24 * 60 * 60)
        await store.save(doomed)
        let kept = makeEntry(owner: ownerA)
        await store.save(kept)

        await store.revoke(introPublicKey: doomed.introPublicKey)

        let listed = await store.listForOwner(ownerA)
        XCTAssertEqual(listed.map(\.introPublicKey), [kept.introPublicKey])
        let foundDoomed = await store.find(introPublicKey: doomed.introPublicKey)
        XCTAssertNil(foundDoomed)
        // The row held an intro PRIVATE key; revoke must remove it at
        // rest, not just hide it from reads.
        XCTAssertEqual(rawEntryCount(), 1)
    }

    func test_revoke_publishesToTheOwnersStream_soThePumpDropsTheInbox() async {
        let doomed = makeEntry(owner: ownerB)
        await store.save(doomed)

        var iterator = store.entriesStream(forOwner: ownerB).makeAsyncIterator()
        _ = await iterator.next()  // initial snapshot

        await store.revoke(introPublicKey: doomed.introPublicKey)
        let afterRevoke = await iterator.next()

        XCTAssertEqual(afterRevoke, [],
                       "the intro pump must stop subscribing a revoked inbox")
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
