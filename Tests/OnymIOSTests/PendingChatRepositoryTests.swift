import XCTest
@testable import OnymInbox
@testable import OnymIdentity

/// The per-identity snapshot layer over `PendingChatStore`. Same
/// contract as `GroupRepository`, because it feeds the same list:
/// subscribers see one identity's rows, and every mutation re-yields.
final class PendingChatRepositoryTests: XCTestCase {

    private let alice = IdentityID()
    private let bob = IdentityID()

    func test_snapshots_areFilteredToTheCurrentIdentity() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        await repository.record(makeChat(group: 0x11, owner: alice))
        await repository.record(makeChat(group: 0x22, owner: bob))

        let mine = try await firstSnapshot(from: repository)
        XCTAssertEqual(mine.map(\.ownerIdentityID), [alice])
    }

    func test_switchingIdentity_reyieldsTheOtherIdentitysRows() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        await repository.record(makeChat(group: 0x22, owner: bob))

        let asAlice = try await firstSnapshot(from: repository)
        XCTAssertTrue(asAlice.isEmpty)
        await repository.setCurrentIdentity(bob)
        let asBob = try await firstSnapshot(from: repository)
        XCTAssertEqual(asBob.count, 1)
    }

    func test_noIdentitySelected_yieldsNothing() async throws {
        // Cold start before the selection lands. Showing another
        // identity's invitations "until the filter arrives" would be a
        // cross-identity leak on the most-looked-at screen in the app.
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.record(makeChat(group: 0x11, owner: alice))
        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertTrue(snapshot.isEmpty)
    }

    func test_record_reportsWhatTheWriteDid() async {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let chat = makeChat(group: 0x11, owner: alice)

        let first = await repository.record(chat)
        let second = await repository.record(chat)
        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(second, .alreadyPresent)
    }

    func test_markRequested_isVisibleToSubscribers() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let chat = makeChat(group: 0x11, owner: alice)
        await repository.record(chat)

        await repository.markRequested(id: chat.id)

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.first?.status, .requested)
    }

    func test_markFailed_carriesTheReasonTheThreadShows() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let chat = makeChat(group: 0x11, owner: alice)
        await repository.record(chat)

        await repository.markFailed(id: chat.id, reason: "no relay connection")

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.first?.status, .failed(reason: "no relay connection"))
    }

    func test_consumeForMaterializedGroups_dropsTheWaitThatIsOver() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let landed = makeChat(group: 0x11, owner: alice)
        let waiting = makeChat(group: 0x22, owner: alice)
        await repository.record(landed)
        await repository.record(waiting)

        await repository.consumeForMaterializedGroups([landed.groupIDHex])

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.map(\.groupIDHex), [waiting.groupIDHex])
    }

    func test_consumeForMaterializedGroups_ignoresGroupsWithNoPendingRow() async throws {
        // Every group snapshot flows through here on every emission, and
        // almost none of them match. Touching the store for those would
        // re-yield the whole list to every subscriber on each repaint.
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let chat = makeChat(group: 0x11, owner: alice)
        await repository.record(chat)

        await repository.consumeForMaterializedGroups(["ffff"])

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.count, 1)
    }

    func test_consumeForMaterializedGroups_worksAgainstAColdCache() async throws {
        // Launch order isn't guaranteed: the group watcher starts from
        // the flow while the startup `reload()` runs from another task,
        // so the first emission can arrive before anything has been
        // read. Deciding "no rows match" from an unread cache leaves the
        // stale row in the list until some unrelated group mutation.
        let store = InMemoryPendingChatStore()
        let chat = makeChat(group: 0x11, owner: alice)
        await store.insert(chat)

        let repository = PendingChatRepository(store: store)
        await repository.setCurrentIdentity(alice)
        await repository.consumeForMaterializedGroups([chat.groupIDHex])

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertTrue(snapshot.isEmpty, "the row must go even if the cache was never read")
        let rows = await store.list()
        XCTAssertTrue(rows.isEmpty, "and it must go from the store, not just the cache")
    }

    func test_removeForOwner_cascades() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        await repository.record(makeChat(group: 0x11, owner: alice))

        await repository.removeForOwner(alice)

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertTrue(snapshot.isEmpty)
    }

    func test_currentChats_readsAcrossIdentities() async {
        // The deeplink path asks "does this device already have a row
        // for this group?" before creating one, and the answer must not
        // depend on which identity happens to be selected.
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        await repository.record(makeChat(group: 0x11, owner: alice))
        await repository.record(makeChat(group: 0x22, owner: bob))

        let all = await repository.currentChats()
        XCTAssertEqual(Set(all.map(\.ownerIdentityID)), [alice, bob])
    }

    // MARK: - Helpers

    /// Subscribers get the current list on subscribe, so one read of a
    /// fresh stream is the current snapshot.
    private func firstSnapshot(
        from repository: PendingChatRepository
    ) async throws -> [PendingChat] {
        for await snapshot in repository.snapshots { return snapshot }
        return []
    }

    private func makeChat(group: UInt8, owner: IdentityID) -> PendingChat {
        PendingChat(
            groupID: Data(repeating: group, count: 32),
            ownerIdentityID: owner,
            introPublicKey: Data(repeating: 0x44, count: 32),
            groupName: "Maple Garden",
            inviterAlias: "Alice",
            invitationMessage: nil,
            receivedAt: Date(),
            status: .offered
        )
    }
}
