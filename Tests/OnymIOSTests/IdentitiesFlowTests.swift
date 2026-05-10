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

    // MARK: - Restore (issue #99)

    func test_restoreIsValid_isFalseForEmptyAndGarbage_andTrueForFreshPhrase() async throws {
        _ = try await repo.bootstrap()
        await flow.start()

        // Empty / whitespace → not valid (also: hint stays neutral so a
        // fresh visit isn't immediately red).
        flow.restorePhrase = ""
        XCTAssertFalse(flow.restoreIsValid)
        flow.restorePhrase = "   \n  "
        XCTAssertFalse(flow.restoreIsValid)

        // Garbage with right wordcount → not valid (checksum fails).
        flow.restorePhrase = Array(repeating: "abandon", count: 12).joined(separator: " ")
        XCTAssertFalse(flow.restoreIsValid,
                       "12 × 'abandon' has bad checksum and must not validate")

        // Round-trip a freshly generated phrase — the canonical happy
        // path. We can't hardcode a vector here without leaking a phrase
        // into the repo; `Bip39.generateMnemonic()` is deterministic
        // per-call only in shape (12 random words + valid checksum).
        let valid = Bip39.generateMnemonic()
        flow.restorePhrase = valid
        XCTAssertTrue(flow.restoreIsValid,
                      "freshly-minted BIP-39 phrase must round-trip as valid")
    }

    func test_submitRestore_validPhrase_addsAndSelectsAlongsideExisting() async throws {
        _ = try await repo.bootstrap()
        await flow.start()
        XCTAssertEqual(flow.identities.count, 1)
        let originalID = try XCTUnwrap(flow.currentID)

        // Use a fresh BIP-39 phrase. After restore: there must be TWO
        // identities (the bootstrap is preserved, NOT wiped — that's
        // the legacy `IdentityRepository.restore` semantics, which is
        // explicitly NOT what this flow uses), and the new one is
        // active.
        flow.restorePhrase = Bip39.generateMnemonic()
        flow.restoreAlias = "Restored"

        let success = await flow.submitRestore()
        XCTAssertTrue(success, "valid phrase + repo.add must succeed")

        // Stream propagation is async — wait for the identities list to
        // catch up to the post-add state before asserting.
        try await waitFor { await self.flow.identities.count >= 2 }

        XCTAssertEqual(flow.identities.count, 2,
                       "restore must add alongside existing identities, not wipe them")
        let restored = try XCTUnwrap(
            flow.identities.first(where: { $0.id != originalID })
        )
        XCTAssertEqual(restored.name, "Restored")
        try await waitFor { await self.flow.currentID == restored.id }
        XCTAssertEqual(flow.currentID, restored.id,
                       "restored identity must become the active selection")

        // Form clears on success.
        XCTAssertTrue(flow.restorePhrase.isEmpty)
        XCTAssertTrue(flow.restoreAlias.isEmpty)
        XCTAssertNil(flow.restoreError)

        // Bootstrap survives.
        XCTAssertNotNil(flow.identities.first(where: { $0.id == originalID }),
                        "bootstrapped identity must survive restore")
    }

    /// Cross-platform interop check (the issue's "BLS public key matches
    /// the original identity's" item): the same phrase must derive the
    /// same BLS keypair across two `submitRestore` calls. Different
    /// IdentityIDs but identical key material.
    func test_submitRestore_samePhrase_yieldsSameBLSKey() async throws {
        _ = try await repo.bootstrap()
        await flow.start()

        let phrase = Bip39.generateMnemonic()
        flow.restorePhrase = phrase
        XCTAssertTrue(await flow.submitRestore())
        try await waitFor { await self.flow.identities.count >= 2 }
        let firstID = try XCTUnwrap(flow.currentID)
        let firstBLS = try XCTUnwrap(
            flow.identities.first(where: { $0.id == firstID })?.blsPublicKey
        )

        flow.restorePhrase = phrase
        XCTAssertTrue(await flow.submitRestore())
        try await waitFor { await self.flow.identities.count >= 3 }
        try await waitFor { await self.flow.currentID != firstID }
        let secondID = try XCTUnwrap(flow.currentID)
        XCTAssertNotEqual(firstID, secondID, "each restore mints a fresh IdentityID")
        let secondBLS = try XCTUnwrap(
            flow.identities.first(where: { $0.id == secondID })?.blsPublicKey
        )
        XCTAssertEqual(firstBLS, secondBLS,
                       "same phrase must derive the same BLS keypair (cross-device interop)")
    }

    func test_submitRestore_invalidPhrase_setsErrorAndDoesNotAdd() async throws {
        _ = try await repo.bootstrap()
        await flow.start()

        flow.restorePhrase = "not a real phrase at all definitely garbage"
        let success = await flow.submitRestore()
        XCTAssertFalse(success)
        XCTAssertEqual(flow.identities.count, 1, "no identity added on failure")
        XCTAssertNotNil(flow.restoreError)
    }

    func test_cancelRestore_clearsState() async throws {
        flow.restorePhrase = "some text"
        flow.restoreAlias = "alice"
        flow.restoreError = "boom"
        flow.cancelRestore()
        XCTAssertTrue(flow.restorePhrase.isEmpty)
        XCTAssertTrue(flow.restoreAlias.isEmpty)
        XCTAssertNil(flow.restoreError)
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
