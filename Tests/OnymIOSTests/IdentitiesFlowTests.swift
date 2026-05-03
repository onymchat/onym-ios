import XCTest
@testable import OnymIOS

/// View-model tests for `IdentitiesFlow`. Real `IdentityRepository`
/// (isolated keychain) drives the streams; the flow is exercised
/// through its intent methods and observable state.
@MainActor
final class IdentitiesFlowTests: XCTestCase {
    private var keychain: IdentityKeychainStore!
    private var repo: IdentityRepository!
    private var flow: IdentitiesFlow!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "flow-\(UUID().uuidString)")
        repo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
        flow = IdentitiesFlow(repository: repo)
    }

    override func tearDown() async throws {
        flow?.stop()
        try? keychain?.wipeAll()
        keychain = nil
        repo = nil
        flow = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func test_start_pullsCurrentIdentities() async throws {
        _ = try await repo.bootstrap()
        await flow.start()
        XCTAssertEqual(flow.identities.count, 1)
        XCTAssertEqual(flow.currentID, flow.identities.first?.id)
    }

    // MARK: - Add

    func test_submitAdd_freshIdentity_addsAndClearsForm() async throws {
        _ = try await repo.bootstrap()
        await flow.start()

        flow.pendingName = "Work"
        flow.submitAdd()
        try await waitFor { await self.flow.identities.count >= 2 }

        XCTAssertEqual(flow.identities.count, 2)
        XCTAssertTrue(flow.identities.contains(where: { $0.name == "Work" }))
        XCTAssertEqual(flow.pendingName, "", "form clears on success")
        XCTAssertNil(flow.addError)
    }

    func test_submitAdd_invalidMnemonic_setsError() async throws {
        _ = try await repo.bootstrap()
        await flow.start()

        flow.pendingMnemonic = "not a real mnemonic"
        flow.submitAdd()
        try await waitFor { await self.flow.addError != nil }

        XCTAssertNotNil(flow.addError)
        XCTAssertEqual(flow.identities.count, 1, "no identity added on failure")
    }

    // MARK: - Select

    func test_select_switchesCurrentID() async throws {
        _ = try await repo.bootstrap()
        let secondID = try await repo.add(name: "Work")
        await flow.start()
        XCTAssertNotEqual(flow.currentID, secondID)

        flow.select(secondID)
        try await waitFor { await self.flow.currentID == secondID }
        XCTAssertEqual(flow.currentID, secondID)
    }

    // MARK: - Remove

    func test_canConfirmRemoval_requiresExactNameMatch() async throws {
        _ = try await repo.bootstrap()
        let workID = try await repo.add(name: "Work")
        await flow.start()
        let summary = try XCTUnwrap(flow.identities.first(where: { $0.id == workID }))

        flow.startRemoval(of: summary)
        XCTAssertFalse(flow.canConfirmRemoval, "empty text never confirms")

        flow.pendingRemovalConfirmText = "work"  // wrong case
        XCTAssertFalse(flow.canConfirmRemoval)

        flow.pendingRemovalConfirmText = "Work"
        XCTAssertTrue(flow.canConfirmRemoval)
    }

    func test_confirmRemoval_dropsIdentity() async throws {
        _ = try await repo.bootstrap()
        let workID = try await repo.add(name: "Work")
        await flow.start()
        let summary = try XCTUnwrap(flow.identities.first(where: { $0.id == workID }))

        flow.startRemoval(of: summary)
        flow.pendingRemovalConfirmText = "Work"
        flow.confirmRemoval()
        try await waitFor { await self.flow.identities.count == 1 }

        XCTAssertFalse(flow.identities.contains(where: { $0.id == workID }))
        XCTAssertNil(flow.pendingRemoval, "confirm sheet closes on success")
    }

    func test_cancelRemoval_doesNotRemove() async throws {
        _ = try await repo.bootstrap()
        let workID = try await repo.add(name: "Work")
        await flow.start()
        let summary = try XCTUnwrap(flow.identities.first(where: { $0.id == workID }))

        flow.startRemoval(of: summary)
        flow.cancelRemoval()

        XCTAssertNil(flow.pendingRemoval)
        XCTAssertEqual(flow.identities.count, 2, "no identity removed on cancel")
    }

    // MARK: - Helpers

    private func waitFor(
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.02,
        _ predicate: @Sendable @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        XCTFail("waitFor predicate never became true within \(timeout)s",
                file: file, line: line)
    }
}
