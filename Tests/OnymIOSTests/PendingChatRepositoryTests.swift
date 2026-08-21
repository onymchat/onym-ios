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

    func test_markFailed_carriesACodeTheThreadCanRenderInAnyLanguage() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let chat = makeChat(group: 0x11, owner: alice)
        await repository.record(chat)

        await repository.markFailed(id: chat.id, failure: .transport)

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.first?.status, .failed(.transport))
    }

    func test_consumeForMaterialized_dropsTheWaitThatIsOver() async throws {
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let landed = makeChat(group: 0x11, owner: alice)
        let waiting = makeChat(group: 0x22, owner: alice)
        await repository.record(landed)
        await repository.record(waiting)

        await repository.consumeForMaterialized([(landed.groupIDHex, alice)])

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.map(\.groupIDHex), [waiting.groupIDHex])
    }

    func test_consumeForMaterialized_touchesNothingWhenNoRowMatches() async throws {
        // Every group snapshot flows through here on every emission, and
        // almost none of them match. Counting the writes rather than the
        // surviving rows is the point: a row count of 1 also passes for
        // an implementation that deleted nothing but re-yielded the whole
        // list to every subscriber on each repaint.
        let store = CountingPendingChatStore()
        let repository = PendingChatRepository(store: store)
        await repository.setCurrentIdentity(alice)
        await repository.record(makeChat(group: 0x11, owner: alice))
        await store.resetCounts()

        await repository.consumeForMaterialized([("ffff", alice)])

        let deletes = await store.deleteForIDsCalls
        let lists = await store.listCalls
        XCTAssertEqual(deletes, 0, "no row matched, so nothing may be written")
        XCTAssertEqual(lists, 0, "and the list must not be re-read to say so")
        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.count, 1)
    }

    func test_consumeForMaterialized_leavesTheOtherIdentitysRowAlone() async throws {
        // The group stream is filtered to the selected identity, so the
        // pairs arriving here name one owner. Matching on the group
        // alone deleted the other identity's row for the same chat.
        let store = InMemoryPendingChatStore()
        let repository = PendingChatRepository(store: store)
        let mine = makeChat(group: 0x11, owner: alice)
        let theirs = makeChat(group: 0x11, owner: bob)
        await repository.setCurrentIdentity(alice)
        await repository.record(mine)
        await repository.record(theirs)

        await repository.consumeForMaterialized([(mine.groupIDHex, alice)])

        let rows = await store.list()
        XCTAssertEqual(rows.map(\.ownerIdentityID), [bob])
    }

    func test_consumeForMaterialized_worksAgainstAColdCache() async throws {
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
        await repository.consumeForMaterialized([(chat.groupIDHex, alice)])

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

    func test_record_onARepeatOffer_takesTheNewerReplyChannel() async throws {
        // A re-invite mints a fresh intro key and revokes the old one.
        // Keeping the first would seal Accept to a dead address — sent,
        // never heard, waiting forever.
        let repository = PendingChatRepository(store: InMemoryPendingChatStore())
        await repository.setCurrentIdentity(alice)
        let first = makeChat(group: 0x11, owner: alice)
        await repository.record(first)
        await repository.markRequested(id: first.id)

        var reinvite = makeChat(group: 0x11, owner: alice)
        reinvite = PendingChat(
            groupID: reinvite.groupID,
            ownerIdentityID: alice,
            introPublicKey: Data(repeating: 0x99, count: 32),
            groupName: "Maple Garden (renamed)",
            inviterAlias: "Alice",
            invitationMessage: nil,
            receivedAt: Date(),
            status: .offered
        )
        let outcome = await repository.record(reinvite)

        XCTAssertEqual(outcome, .alreadyPresent)
        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertEqual(snapshot.first?.introPublicKey, Data(repeating: 0x99, count: 32))
        XCTAssertEqual(snapshot.first?.groupName, "Maple Garden (renamed)")
        XCTAssertEqual(
            snapshot.first?.status, .requested,
            "the newer key changes where to ask, not what was asked"
        )
    }

    func test_remove_dropsTheRowTheUserSwipedAway() async throws {
        // The only user-initiated delete in the feature, and the one the
        // row's swipe action is gated on.
        let store = InMemoryPendingChatStore()
        let repository = PendingChatRepository(store: store)
        await repository.setCurrentIdentity(alice)
        let chat = makeChat(group: 0x11, owner: alice)
        await repository.record(chat)

        await repository.remove(id: chat.id)

        let snapshot = try await firstSnapshot(from: repository)
        XCTAssertTrue(snapshot.isEmpty)
        let rows = await store.list()
        XCTAssertTrue(rows.isEmpty, "local-only, but it does have to be local")
    }

    func test_currentChats_readsThroughAColdCache() async {
        // The deeplink path's first question on a cold start, before
        // anything has read the store: without the read-through it
        // answers "no rows" and a second waiting room is created beside
        // the one already on disk.
        let store = InMemoryPendingChatStore()
        let chat = makeChat(group: 0x11, owner: alice)
        await store.insert(chat)

        let repository = PendingChatRepository(store: store)
        let all = await repository.currentChats()

        XCTAssertEqual(all.map(\.id), [chat.id])
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

    // MARK: - Spy

    /// Counts what actually reached the store. Used where the claim is
    /// "this did no work" — a claim the surviving rows cannot make.
    private actor CountingPendingChatStore: PendingChatStore {
        private var rows: [PendingChat] = []
        private(set) var deleteForIDsCalls = 0
        private(set) var listCalls = 0

        func resetCounts() {
            deleteForIDsCalls = 0
            listCalls = 0
        }

        @discardableResult
        func insert(_ chat: PendingChat) async -> PendingChatWriteOutcome {
            guard !rows.contains(where: { $0.id == chat.id }) else { return .alreadyPresent }
            rows.append(chat)
            return .inserted
        }

        func setStatus(id: String, status: PendingChat.Status) async {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index].status = status
        }

        func refreshOffer(
            id: String,
            introPublicKey: Data,
            groupName: String?,
            inviterAlias: String,
            invitationMessage: String?
        ) async {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            let existing = rows[index]
            rows[index] = PendingChat(
                groupID: existing.groupID,
                ownerIdentityID: existing.ownerIdentityID,
                introPublicKey: introPublicKey,
                groupName: groupName,
                inviterAlias: inviterAlias,
                invitationMessage: invitationMessage,
                receivedAt: existing.receivedAt,
                status: existing.status
            )
        }

        func setJoinerLabel(id: String, label: String) async {
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index].joinerLabel = label
        }

        func delete(id: String) async {
            rows.removeAll { $0.id == id }
        }

        func deleteForIDs(_ ids: Set<String>) async {
            deleteForIDsCalls += 1
            rows.removeAll { ids.contains($0.id) }
        }

        func deleteOwner(_ ownerIDString: String) async {
            rows.removeAll { $0.ownerIdentityID.rawValue.uuidString == ownerIDString }
        }

        func list() async -> [PendingChat] {
            listCalls += 1
            return rows.sorted { $0.receivedAt > $1.receivedAt }
        }
    }
}
