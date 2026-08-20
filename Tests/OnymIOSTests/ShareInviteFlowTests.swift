import XCTest
@testable import OnymIOS
import OnymIdentity
import OnymGroup

/// State-machine tests for `ShareInviteFlow` — the post-create
/// deeplink-share surface. Mirrors `ShareInviteViewModelTest.kt`.
@MainActor
final class ShareInviteFlowTests: XCTestCase {

    private var keychain: IdentityKeychainStore!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "share-invite-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? keychain?.wipeAll()
        keychain = nil
        try await super.tearDown()
    }

    func test_mintFor_knownGroupAndIdentity_emitsReadyWithParseableLink() async throws {
        let identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        _ = try await identity.bootstrap()
        let resolved = await identity.currentSelectedID()
        let owner = try XCTUnwrap(resolved)

        let store = TestableInMemoryGroupStore()
        let group = makeGroup(id: String(repeating: "ab", count: 32), name: "Family", owner: owner)
        await store.preload([group])
        let groupRepo = GroupRepository(store: store, currentIdentityID: owner)

        let introducer = InviteIntroducer(store: InMemoryIntroKeyStore())
        let flow = ShareInviteFlow(
            identity: identity,
            introducer: introducer,
            groupRepository: groupRepo
        )

        flow.mintFor(groupID: group.id)
        try await waitFor { flow.state.isReady }

        guard case .ready(let link, let groupName) = flow.state else {
            return XCTFail("expected .ready, got \(flow.state)")
        }
        XCTAssertEqual(groupName, "Family")
        // Round-trips back to a capability for the same group.
        let cap = IntroCapability.fromLink(link)
        XCTAssertNotNil(cap)
        XCTAssertEqual(cap?.groupName, "Family")
        XCTAssertEqual(
            cap?.groupId.map { String(format: "%02x", $0) }.joined(),
            group.id
        )
    }

    func test_mintFor_unknownGroup_failsWithoutTouchingStore() async throws {
        let identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        _ = try await identity.bootstrap()
        let resolved = await identity.currentSelectedID()
        let owner = try XCTUnwrap(resolved)

        let store = TestableInMemoryGroupStore()
        // No groups seeded.
        let groupRepo = GroupRepository(store: store, currentIdentityID: owner)
        let introKeyStore = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: introKeyStore)
        let flow = ShareInviteFlow(
            identity: identity,
            introducer: introducer,
            groupRepository: groupRepo
        )

        flow.mintFor(groupID: String(repeating: "ab", count: 32))
        try await waitFor { flow.state.isFailed }

        guard case .failed = flow.state else {
            return XCTFail("expected .failed, got \(flow.state)")
        }
        // No keypair was persisted for an unknown group.
        let listed = await introKeyStore.listForOwner(owner)
        XCTAssertEqual(listed.count, 0)
    }

    func test_mintFor_fromASecondFlowOverTheSameStore_reusesTheLiveLink() async throws {
        let identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        _ = try await identity.bootstrap()
        let resolved = await identity.currentSelectedID()
        let owner = try XCTUnwrap(resolved)

        let store = TestableInMemoryGroupStore()
        let group = makeGroup(id: String(repeating: "ab", count: 32), name: "G", owner: owner)
        await store.preload([group])
        let groupRepo = GroupRepository(store: store, currentIdentityID: owner)
        let introKeyStore = InMemoryIntroKeyStore()
        let introducer = InviteIntroducer(store: introKeyStore)

        // Two flows over one store: the real path (a fresh flow per
        // tap) and deterministic, since the second starts `.idle`.
        let first = ShareInviteFlow(
            identity: identity,
            introducer: introducer,
            groupRepository: groupRepo
        )
        first.mintFor(groupID: group.id)
        try await waitFor { first.state.isReady }
        guard case .ready(let firstLink, _) = first.state else {
            return XCTFail("expected first .ready")
        }

        let second = ShareInviteFlow(
            identity: identity,
            introducer: introducer,
            groupRepository: groupRepo
        )
        second.mintFor(groupID: group.id)
        try await waitFor { second.state.isReady }
        guard case .ready(let secondLink, _) = second.state else {
            return XCTFail("expected second .ready")
        }

        // The share screen is a view onto the group's link, not a link
        // factory; re-entry must not leave a trail of slots.
        XCTAssertEqual(firstLink, secondLink, "re-entry should surface the same link")
        let listed = await introKeyStore.listForOwner(owner)
        XCTAssertEqual(listed.count, 1, "reuse must not persist a second intro slot")
    }

    func test_state_transitionsThroughMinting() async throws {
        let identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        _ = try await identity.bootstrap()
        let resolved = await identity.currentSelectedID()
        let owner = try XCTUnwrap(resolved)

        let store = TestableInMemoryGroupStore()
        let group = makeGroup(id: String(repeating: "ab", count: 32), name: "G", owner: owner)
        await store.preload([group])
        let groupRepo = GroupRepository(store: store, currentIdentityID: owner)
        let flow = ShareInviteFlow(
            identity: identity,
            introducer: InviteIntroducer(store: InMemoryIntroKeyStore()),
            groupRepository: groupRepo
        )

        XCTAssertEqual(flow.state, .idle)
        flow.mintFor(groupID: group.id)
        try await waitFor { flow.state.isReady }
        XCTAssertTrue(flow.state.isReady)
    }

    func test_rotate_doubleTap_onlyRotatesOnce() async throws {
        let identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        _ = try await identity.bootstrap()
        let resolved = await identity.currentSelectedID()
        let owner = try XCTUnwrap(resolved)
        let store = TestableInMemoryGroupStore()
        let group = makeGroup(id: String(repeating: "ab", count: 32), name: "G", owner: owner)
        await store.preload([group])
        let introKeyStore = InMemoryIntroKeyStore()
        let flow = ShareInviteFlow(
            identity: identity,
            introducer: InviteIntroducer(store: introKeyStore),
            groupRepository: GroupRepository(store: store, currentIdentityID: owner)
        )
        flow.mintFor(groupID: group.id)
        try await waitFor { flow.state.isReady }

        // The guard has to bite before the first await, or the second
        // tap slips through while `isRotating` is still false.
        flow.rotateLink(groupID: group.id)
        flow.rotateLink(groupID: group.id)
        try await waitFor { flow.state.isReady && !flow.isRotating }

        let shared = await introKeyStore.listForOwner(owner).filter { $0.label == nil }
        XCTAssertEqual(shared.count, 1, "a second rotate would strand a live key")
    }

    func test_supersededSharedKey_isListedSoItCanBeRevoked() async throws {
        let identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        _ = try await identity.bootstrap()
        let resolved = await identity.currentSelectedID()
        let owner = try XCTUnwrap(resolved)
        let store = TestableInMemoryGroupStore()
        let group = makeGroup(id: String(repeating: "ab", count: 32), name: "G", owner: owner)
        await store.preload([group])
        let introKeyStore = InMemoryIntroKeyStore()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Two unlabelled keys is what a crash mid-rotate leaves. The
        // older one used to be on no list: no revoke, live subscription.
        let stranded = try await InviteIntroducer(store: introKeyStore, now: { t0 })
            .mint(ownerIdentityID: owner, groupId: group.groupIDData)
        let introducer = InviteIntroducer(
            store: introKeyStore,
            now: { t0.addingTimeInterval(60) }
        )
        let current = try await introducer.mint(
            ownerIdentityID: owner, groupId: group.groupIDData
        )
        let flow = ShareInviteFlow(
            identity: identity,
            introducer: introducer,
            groupRepository: GroupRepository(store: store, currentIdentityID: owner)
        )
        flow.mintFor(groupID: group.id)
        try await waitFor { flow.state.isReady }
        try await waitFor { !flow.otherInvites.isEmpty }

        let row = try XCTUnwrap(flow.otherInvites.first)
        XCTAssertEqual(flow.otherInvites.count, 1, "the rendered link is not a row")
        XCTAssertEqual(row.introPublicKey, stranded.introPublicKey)
        XCTAssertNotEqual(row.introPublicKey, current.introPublicKey)
        XCTAssertNil(row.label, "a superseded key has no invitee name; the view names it")

        flow.revoke(row, groupID: group.id)
        try await waitFor { flow.otherInvites.isEmpty }
        let gone = await introKeyStore.find(introPublicKey: stranded.introPublicKey)
        XCTAssertNil(gone)
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
            memberProfiles: [:],
            epoch: 0,
            salt: Data(repeating: 0x44, count: 32),
            commitment: nil,
            tier: .small,
            groupType: .tyranny,
            adminPubkeyHex: nil,
            adminEd25519PubkeyHex: nil,
            isPublishedOnChain: false
        )
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.02,
        _ predicate: @MainActor @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("waitFor predicate never became true within \(timeout)s",
                file: file, line: line)
    }
}

// MARK: - State helpers

private extension ShareInviteFlow.State {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Test doubles

private actor TestableInMemoryGroupStore: GroupStore {
    private var rows: [String: ChatGroup] = [:]

    func preload(_ groups: [ChatGroup]) {
        for group in groups { rows[group.id] = group }
    }

    func list() -> [ChatGroup] {
        rows.values.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func insertOrUpdate(_ group: ChatGroup) -> GroupInsertOutcome {
        let isNew = rows[group.id] == nil
        rows[group.id] = group
        return isNew ? .inserted : .updated
    }

    func markPublished(id: String, ownerIDString: String, commitment: Data?) {
        guard var existing = rows[id] else { return }
        existing.isPublishedOnChain = true
        if let commitment { existing.commitment = commitment }
        rows[id] = existing
    }

    func markRead(id: String, ownerIDString: String, at date: Date) {
        guard var existing = rows[id] else { return }
        existing.lastReadAt = date
        rows[id] = existing
    }

    func delete(id: String, ownerIDString: String) {
        rows.removeValue(forKey: id)
    }

    func deleteOwner(_ ownerIDString: String) {
        rows = rows.filter { $0.value.ownerIdentityID.rawValue.uuidString != ownerIDString }
    }
}
