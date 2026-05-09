import XCTest
@testable import OnymIOS

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

    func test_mintFor_calledTwice_mintsTwoIndependentKeypairs() async throws {
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
        let flow = ShareInviteFlow(
            identity: identity,
            introducer: introducer,
            groupRepository: groupRepo
        )

        flow.mintFor(groupID: group.id)
        try await waitFor { flow.state.isReady }
        guard case .ready(let firstLink, _) = flow.state else {
            return XCTFail("expected first .ready")
        }

        flow.mintFor(groupID: group.id)
        // Wait for the link to actually change (the second mint emits
        // `.minting` then `.ready` again).
        try await waitFor {
            if case .ready(let link, _) = flow.state, link != firstLink { return true }
            return false
        }
        guard case .ready(let secondLink, _) = flow.state else {
            return XCTFail("expected second .ready")
        }

        // Per-link revocation depends on this — re-shares cannot
        // collapse to the same intro slot or revoking one would kill
        // the other.
        XCTAssertNotEqual(firstLink, secondLink, "two shares should produce different links")
        let listed = await introKeyStore.listForOwner(owner)
        XCTAssertEqual(listed.count, 2)
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
    func insertOrUpdate(_ group: ChatGroup) -> Bool {
        let isNew = rows[group.id] == nil
        rows[group.id] = group
        return isNew
    }

    func markPublished(id: String, commitment: Data?) {
        guard var existing = rows[id] else { return }
        existing.isPublishedOnChain = true
        if let commitment { existing.commitment = commitment }
        rows[id] = existing
    }

    func delete(id: String) {
        rows.removeValue(forKey: id)
    }

    func deleteOwner(_ ownerIDString: String) {
        rows = rows.filter { $0.value.ownerIdentityID.rawValue.uuidString != ownerIDString }
    }
}
