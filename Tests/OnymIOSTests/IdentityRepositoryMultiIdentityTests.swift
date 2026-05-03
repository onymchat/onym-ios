import XCTest
@testable import OnymIOS

/// Multi-identity API surface added in PR-2. Verifies add / select /
/// remove flows + the new reactive streams (`identitiesStream`,
/// `currentIdentityID`, `identityRemoved`) behave correctly when the
/// keychain holds more than one identity.
final class IdentityRepositoryMultiIdentityTests: XCTestCase {
    private var keychain: IdentityKeychainStore!
    private var repo: IdentityRepository!

    override func setUp() {
        super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "multi-\(UUID().uuidString)")
        repo = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
    }

    override func tearDown() {
        try? keychain.wipeAll()
        keychain = nil
        repo = nil
        super.tearDown()
    }

    // MARK: - bootstrap + add

    func test_bootstrap_emptyKeychain_generatesDefaultIdentity() async throws {
        let identity = try await repo.bootstrap()
        XCTAssertNotNil(identity.recoveryPhrase)
        let summaries = await repo.currentIdentities()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].name, "Identity",
                       "first auto-bootstrapped identity uses the bare 'Identity' name")
    }

    func test_add_secondIdentity_doesNotChangeSelection() async throws {
        let first = try await repo.bootstrap()
        let secondID = try await repo.add(name: "Work")

        let summaries = await repo.currentIdentities()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map(\.name)), ["Identity", "Work"])

        let current = try await XCTUnwrapAsync(await repo.currentIdentity())
        XCTAssertEqual(current.blsPublicKey, first.blsPublicKey,
                       "adding a second identity must NOT auto-select it")
        XCTAssertNotEqual(secondID, IdentityID(),
                          "add() must return the new ID, not a fresh ad-hoc UUID")
    }

    func test_add_namesGetTrimmed_andEmptyFallsBackToSlotDefault() async throws {
        _ = try await repo.bootstrap()
        let id = try await repo.add(name: "   ")
        let summary = await repo.currentIdentities().first(where: { $0.id == id })
        XCTAssertEqual(summary?.name, "Identity 2",
                       "whitespace-only names must fall back to the slot default")
    }

    // MARK: - select

    func test_select_switchesCurrentAndYieldsOnStreams() async throws {
        _ = try await repo.bootstrap()
        let secondID = try await repo.add(name: "Work")

        var iterator = repo.currentIdentityID.makeAsyncIterator()
        _ = await iterator.next()  // initial value (current ID after bootstrap+add)
        try await repo.select(secondID)
        let switched = await iterator.next()
        XCTAssertEqual(switched, secondID)

        let current = try await XCTUnwrapAsync(await repo.currentIdentity())
        let summary = await repo.currentIdentities().first(where: { $0.id == secondID })
        XCTAssertEqual(current.blsPublicKey, summary?.blsPublicKey)
    }

    func test_select_unknownID_isNoOp() async throws {
        let first = try await repo.bootstrap()
        try await repo.select(IdentityID())  // never added
        let current = try await XCTUnwrapAsync(await repo.currentIdentity())
        XCTAssertEqual(current.blsPublicKey, first.blsPublicKey)
    }

    // MARK: - remove

    func test_remove_currentIdentity_picksAnotherAndFiresRemovedStream() async throws {
        _ = try await repo.bootstrap()
        let secondID = try await repo.add(name: "Work")

        // Subscribe to the removal stream BEFORE doing the removal so we
        // catch the yielded ID.
        let removedTask = Task { () -> IdentityID? in
            for await id in repo.identityRemoved { return id }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // Switch to the new one so the removal hits the "current" branch
        // and forces a fallback selection.
        try await repo.select(secondID)
        try await repo.remove(secondID)

        let removed = await removedTask.value
        XCTAssertEqual(removed, secondID)

        let summaries = await repo.currentIdentities()
        XCTAssertEqual(summaries.count, 1, "one identity remains after removal")
        let current = try await XCTUnwrapAsync(await repo.currentIdentity())
        XCTAssertEqual(current.blsPublicKey, summaries[0].blsPublicKey,
                       "currentID falls back to the surviving identity")
    }

    func test_remove_lastIdentity_clearsCurrent() async throws {
        let onlyID = try await repo.add(name: "Solo")
        try await repo.remove(onlyID)
        let current = await repo.currentIdentity()
        XCTAssertNil(current, "no identities → no current")
        let summaries = await repo.currentIdentities()
        XCTAssertEqual(summaries, [])
    }

    func test_remove_nonCurrentIdentity_keepsCurrent() async throws {
        let first = try await repo.bootstrap()
        let secondID = try await repo.add(name: "Work")
        try await repo.remove(secondID)
        let current = try await XCTUnwrapAsync(await repo.currentIdentity())
        XCTAssertEqual(current.blsPublicKey, first.blsPublicKey,
                       "removing a non-current identity leaves the current selection alone")
    }

    // MARK: - Stream replay

    func test_identitiesStream_replaysCurrentValueOnSubscribe() async throws {
        _ = try await repo.bootstrap()
        _ = try await repo.add(name: "Work")
        var iterator = repo.identitiesStream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 2,
                       "subscribe replays the post-bootstrap+add count immediately")
    }

    // MARK: - Selection persistence across repository instances

    func test_currentSelection_persistsAcrossRepoRecreation() async throws {
        // First repo: bootstrap + add + select the second one.
        _ = try await repo.bootstrap()
        let secondID = try await repo.add(name: "Work")
        try await repo.select(secondID)

        // Create a fresh repo against the same keychain — selection
        // should be restored from the persisted store.
        let selectionStore = SelectedIdentityStore.inMemory(initial: secondID)
        let revived = IdentityRepository(keychain: keychain, selectionStore: selectionStore)
        _ = try await revived.bootstrap()
        let current = try await XCTUnwrapAsync(await revived.currentIdentity())
        let summaries = await revived.currentIdentities()
        let secondSummary = summaries.first(where: { $0.id == secondID })
        XCTAssertEqual(current.blsPublicKey, secondSummary?.blsPublicKey,
                       "previously-selected ID must come back as current")
    }

    // MARK: - Helpers

    private func XCTUnwrapAsync<T: Sendable>(
        _ value: @autoclosure () async throws -> T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> T {
        let resolved = try await value()
        return try XCTUnwrap(resolved, file: file, line: line)
    }
}
