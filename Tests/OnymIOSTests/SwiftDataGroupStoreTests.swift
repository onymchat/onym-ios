import XCTest
@testable import OnymIOS

/// Round-trip tests for `SwiftDataGroupStore`. Uses
/// `SwiftDataGroupStore.inMemory()` so the on-disk store under
/// Application Support isn't touched. Encrypted columns go through
/// the real `StorageEncryption` (the storage root key lives in the
/// shared Keychain — same dependency every other persistence test in
/// this target has).
final class SwiftDataGroupStoreTests: XCTestCase {

    private var store: SwiftDataGroupStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataGroupStore.inMemory()
    }

    override func tearDown() async throws {
        store = nil
        try await super.tearDown()
    }

    // MARK: - Round-trip

    func test_insertOrUpdate_thenList_roundtripsAllFields() async {
        let group = makeGroup(
            id: "aa".repeated(32),
            name: "Family",
            adminPubkeyHex: "ee".repeated(48)
        )
        let inserted = await store.insertOrUpdate(group)
        XCTAssertTrue(inserted)

        let listed = await store.list()
        XCTAssertEqual(listed.count, 1)
        let first = listed[0]
        XCTAssertEqual(first.id, group.id)
        XCTAssertEqual(first.name, "Family")
        XCTAssertEqual(first.groupSecret, group.groupSecret)
        XCTAssertEqual(first.salt, group.salt)
        XCTAssertEqual(first.commitment, group.commitment)
        XCTAssertEqual(first.tier, .small)
        XCTAssertEqual(first.groupType, .tyranny)
        XCTAssertEqual(first.adminPubkeyHex, "ee".repeated(48))
        XCTAssertEqual(first.epoch, group.epoch)
        XCTAssertFalse(first.isPublishedOnChain)
        XCTAssertEqual(first.members.count, group.members.count)
        XCTAssertEqual(first.members.first?.publicKeyCompressed,
                       group.members.first?.publicKeyCompressed)
        XCTAssertEqual(first.memberProfiles, group.memberProfiles)
    }

    // MARK: - Member profiles

    func test_insertOrUpdate_persistsMemberProfiles() async {
        let aliceHex = "11".repeated(48)
        let bobHex = "22".repeated(48)
        let profiles: [String: MemberProfile] = [
            aliceHex: MemberProfile(
                alias: "alice",
                inboxPublicKey: Data(repeating: 0xAA, count: 32),
                sendingPubkey: Data(repeating: 0xE1, count: 32)
            ),
            bobHex: MemberProfile(
                alias: "bob",
                inboxPublicKey: Data(repeating: 0xBB, count: 32),
                sendingPubkey: Data(repeating: 0xE2, count: 32)
            ),
        ]
        let group = makeGroup(
            id: "ab".repeated(32),
            name: "Profiled",
            memberProfiles: profiles
        )
        _ = await store.insertOrUpdate(group)

        let listed = await store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].memberProfiles, profiles)
    }

    func test_insertOrUpdate_emptyProfilesRoundtripAsEmptyDict() async {
        let group = makeGroup(id: "cd".repeated(32), name: "No profiles")
        _ = await store.insertOrUpdate(group)

        let listed = await store.list()
        XCTAssertEqual(listed[0].memberProfiles, [:])
    }

    // MARK: - Avatar

    func test_insertOrUpdate_persistsAvatar() async {
        let avatar = Data(repeating: 0xAB, count: 1234)
        var group = makeGroup(id: "a0".repeated(32), name: "With photo")
        group.avatarJPEG = avatar
        _ = await store.insertOrUpdate(group)

        let listed = await store.list()
        XCTAssertEqual(listed[0].avatarJPEG, avatar)
    }

    func test_insertOrUpdate_nilAvatarRoundtripsAsNil() async {
        let group = makeGroup(id: "a1".repeated(32), name: "No photo")
        _ = await store.insertOrUpdate(group)

        let listed = await store.list()
        XCTAssertNil(listed[0].avatarJPEG)
    }

    func test_insertOrUpdate_clearsAvatarOnUpdate() async {
        var group = makeGroup(id: "a2".repeated(32), name: "G")
        group.avatarJPEG = Data(repeating: 0x01, count: 64)
        _ = await store.insertOrUpdate(group)

        var cleared = group
        cleared.avatarJPEG = nil
        _ = await store.insertOrUpdate(cleared)

        let listed = await store.list()
        XCTAssertNil(listed[0].avatarJPEG)
    }

    // MARK: - Idempotence

    func test_insertOrUpdate_secondCallUpdatesInPlace() async {
        let original = makeGroup(id: "bb".repeated(32), name: "Old name")
        _ = await store.insertOrUpdate(original)

        var updated = original
        updated.epoch = 7
        updated.commitment = Data(repeating: 0x99, count: 32)
        let inserted = await store.insertOrUpdate(updated)
        XCTAssertFalse(inserted, "second insertOrUpdate on the same id is an update")

        let listed = await store.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].epoch, 7)
        XCTAssertEqual(listed[0].commitment, Data(repeating: 0x99, count: 32))
    }

    // MARK: - markPublished

    func test_markPublished_flipsFlagAndStoresCommitment() async {
        let group = makeGroup(id: "cc".repeated(32), name: "G")
        _ = await store.insertOrUpdate(group)

        let onchainCommitment = Data(repeating: 0x42, count: 32)
        await store.markPublished(
            id: group.id,
            ownerIDString: group.ownerIdentityID.rawValue.uuidString,
            commitment: onchainCommitment
        )

        let listed = await store.list()
        XCTAssertTrue(listed[0].isPublishedOnChain)
        XCTAssertEqual(listed[0].commitment, onchainCommitment)
    }

    func test_markPublished_unknownIdIsNoOp() async {
        await store.markPublished(
            id: "ff".repeated(32),
            ownerIDString: IdentityID().rawValue.uuidString,
            commitment: nil
        )
        let listed = await store.list()
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - delete

    func test_delete_removesRow() async {
        let group = makeGroup(id: "dd".repeated(32), name: "G")
        _ = await store.insertOrUpdate(group)
        let beforeDelete = await store.list()
        XCTAssertEqual(beforeDelete.count, 1)

        await store.delete(id: group.id, ownerIDString: group.ownerIdentityID.rawValue.uuidString)
        let afterDelete = await store.list()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    // MARK: - Multi-identity (same group id, two owners)

    /// Regression: two identities on one device joining the SAME
    /// on-chain group must each keep their own row. Before the
    /// composite `(id, owner)` key, the second `insertOrUpdate`
    /// overwrote the first identity's owner — "last invited identity
    /// wins" and the chat vanished for the earlier one.
    func test_insertOrUpdate_sameGroupIdDifferentOwners_keepsBothRows() async {
        let sharedID = "fe".repeated(32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        let groupA = makeGroup(id: sharedID, name: "A's copy", ownerIdentityID: ownerA)
        let groupB = makeGroup(id: sharedID, name: "B's copy", ownerIdentityID: ownerB)

        let insertedA = await store.insertOrUpdate(groupA)
        let insertedB = await store.insertOrUpdate(groupB)
        XCTAssertTrue(insertedA)
        XCTAssertTrue(insertedB, "second owner must be a fresh insert, not an in-place overwrite")

        let listed = await store.list()
        XCTAssertEqual(listed.count, 2, "both identities keep their own row")
        let owners = Set(listed.map(\.ownerIdentityID))
        XCTAssertEqual(owners, [ownerA, ownerB])
    }

    /// Deleting a group for one identity leaves the other identity's
    /// copy of the same group id intact.
    func test_delete_isScopedToOwner() async {
        let sharedID = "fd".repeated(32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeGroup(id: sharedID, name: "A", ownerIdentityID: ownerA))
        _ = await store.insertOrUpdate(makeGroup(id: sharedID, name: "B", ownerIdentityID: ownerB))

        await store.delete(id: sharedID, ownerIDString: ownerA.rawValue.uuidString)

        let listed = await store.list()
        XCTAssertEqual(listed.map(\.ownerIdentityID), [ownerB])
    }

    /// `markPublished` flips only the addressed identity's row.
    func test_markPublished_isScopedToOwner() async {
        let sharedID = "fc".repeated(32)
        let ownerA = IdentityID()
        let ownerB = IdentityID()
        _ = await store.insertOrUpdate(makeGroup(id: sharedID, name: "A", ownerIdentityID: ownerA))
        _ = await store.insertOrUpdate(makeGroup(id: sharedID, name: "B", ownerIdentityID: ownerB))

        await store.markPublished(
            id: sharedID,
            ownerIDString: ownerA.rawValue.uuidString,
            commitment: Data(repeating: 0x7, count: 32)
        )

        let listed = await store.list()
        let a = listed.first { $0.ownerIdentityID == ownerA }
        let b = listed.first { $0.ownerIdentityID == ownerB }
        XCTAssertEqual(a?.isPublishedOnChain, true)
        XCTAssertEqual(b?.isPublishedOnChain, false, "the other identity's row is untouched")
    }

    // MARK: - sort

    func test_list_sortsByCreatedAtDescending() async {
        let older = makeGroup(
            id: "01".repeated(32),
            name: "older",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = makeGroup(
            id: "02".repeated(32),
            name: "newer",
            createdAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        _ = await store.insertOrUpdate(older)
        _ = await store.insertOrUpdate(newer)

        let listed = await store.list()
        XCTAssertEqual(listed.map(\.id), [newer.id, older.id])
    }

    // MARK: - Helpers

    private func makeGroup(
        id: String,
        name: String,
        adminPubkeyHex: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        ownerIdentityID: IdentityID = IdentityID(),
        memberProfiles: [String: MemberProfile] = [:]
    ) -> ChatGroup {
        let member = GovernanceMember(
            publicKeyCompressed: Data(repeating: 0x11, count: 48),
            leafHash: Data(repeating: 0x22, count: 32)
        )
        return ChatGroup(
            id: id,
            ownerIdentityID: ownerIdentityID,
            name: name,
            groupSecret: Data(repeating: 0x33, count: 32),
            createdAt: createdAt,
            members: [member],
            memberProfiles: memberProfiles,
            epoch: 0,
            salt: Data(repeating: 0x44, count: 32),
            commitment: Data(repeating: 0x55, count: 32),
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: adminPubkeyHex,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: false
        )
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
