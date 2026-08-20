import XCTest
@testable import OnymIOS
import OnymFoundation
@testable import OnymIdentity

/// Each test uses its own Keychain service so test runs are isolated and
/// do not collide with the production identity item or with each other.
/// Tests hit the real Keychain (no mocks) — the simulator Keychain is the
/// thing the app actually uses, and a mock here would defeat the point of
/// integration-testing the persistence layer.
final class IdentityRepositoryTests: XCTestCase {
    private var keychain: IdentityKeychainStore!
    private var repo: IdentityRepository!

    override func setUp() {
        super.setUp()
        keychain = IdentityKeychainStore(
            testNamespace: "tests-\(UUID().uuidString)"
        )
        repo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: .inMemory(initiallySet: true),
            protectedData: .always
        )
    }

    override func tearDown() {
        try? keychain.wipeAll()
        keychain = nil
        repo = nil
        super.tearDown()
    }

    // MARK: - bootstrap

    func test_bootstrap_freshInstall_generatesAndPersistsBip39Identity() async throws {
        let identity = try await repo.bootstrap()

        XCTAssertEqual(identity.nostrPublicKey.count, 32)
        XCTAssertEqual(identity.blsPublicKey.count, 48)
        XCTAssertEqual(identity.stellarPublicKey.count, 32)
        XCTAssertEqual(identity.inboxPublicKey.count, 32)
        XCTAssertEqual(identity.inboxTag.count, 16)
        XCTAssertTrue(identity.stellarAccountID.hasPrefix("G"))
        XCTAssertEqual(identity.stellarAccountID.count, 56,
                       "Stellar StrKey account ID is always 56 chars")
        XCTAssertNotNil(identity.recoveryPhrase)
        XCTAssertEqual(identity.recoveryPhrase?.split(separator: " ").count, 12)

        let ids = try keychain.list()
        XCTAssertEqual(ids.count, 1, "bootstrap must persist exactly one identity")
        let stored = try keychain.read(ids[0])
        XCTAssertNotNil(stored, "bootstrap must persist to Keychain")
        XCTAssertEqual(stored?.entropy?.count, 16)
        XCTAssertEqual(stored?.nostrSecretKey.count, 32)
        XCTAssertEqual(stored?.blsSecretKey.count, 32)
    }

    /// **Derivation fixture.** Locks in derivation against the canonical BIP39
    /// test mnemonic so any change to a salt / info string (HKDF for nostr,
    /// BLS, Stellar Ed25519, X25519, or the `sep-inbox-v1` SHA-256 tag)
    /// breaks this test loudly.
    ///
    /// Salts: `app.onym.bip39` (root entropy → secrets) and `app.onym.ios`
    /// (nostr secret → Stellar/X25519 seeds). The `chat.onym.*` rebrand
    /// changed these, so the values below diverge from the historical
    /// `stellar-mls` / onym-android fixtures — cross-platform interop is
    /// broken until the other platforms adopt the same salts.
    func test_derivation_matchesCrossPlatformFixture() async throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let identity = try await repo.restore(mnemonic: mnemonic)

        XCTAssertEqual(
            identity.nostrPublicKey.hex,
            "d8631b8e96d3d3d6d42cdadd07bc6db04108367dc2ce2d5e9b9a524123dc0821"
        )
        XCTAssertEqual(
            identity.blsPublicKey.hex,
            "a5859e962056987df69617fa41318641def18a1f78959951d1cf07bd164a6dcb50962786c8ead48c4e6aab5db6ce8f10"
        )
        XCTAssertEqual(
            identity.stellarPublicKey.hex,
            "7a33c09cdb7f51fe723a4003d2f28272cddc8fa2cf3d74a374a5f2ee6fb1fcdc"
        )
        XCTAssertEqual(
            identity.stellarAccountID,
            "GB5DHQE43N7VD7TSHJAAHUXSQJZM3XEPULHT25FDOSS7F3TPWH6NYJ7A"
        )
        XCTAssertEqual(
            identity.inboxPublicKey.hex,
            "66ac34309b3b73163b628c2c40174ea76d58d4eb769172611e5c42f9a0cefe5f"
        )
        XCTAssertEqual(
            identity.inboxTag,
            "f462ae97384bd242"
        )
    }

    func test_bootstrap_isIdempotent() async throws {
        let first = try await repo.bootstrap()
        let second = try await repo.bootstrap()

        XCTAssertEqual(first, second, "second bootstrap must return the same identity")
    }

    func test_bootstrap_picksUpExistingKeychainItem() async throws {
        let first = try await repo.bootstrap()

        // Fresh repo against the same Keychain — should load, not regenerate.
        let secondRepo = IdentityRepository(
            keychain: keychain,
            installMarker: .inMemory(initiallySet: true),
            protectedData: .always
        )
        let loaded = try await secondRepo.bootstrap()

        XCTAssertEqual(first, loaded)
    }

    // MARK: - restore

    func test_restore_replacesIdentityWithMnemonicDerivedKeys() async throws {
        let original = try await repo.bootstrap()
        let originalMnemonic = try XCTUnwrap(original.recoveryPhrase)

        // Restore from a *different* mnemonic should yield a different identity.
        let differentMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        XCTAssertNotEqual(differentMnemonic, originalMnemonic)
        let restored = try await repo.restore(mnemonic: differentMnemonic)

        XCTAssertNotEqual(restored.nostrPublicKey, original.nostrPublicKey)
        XCTAssertEqual(restored.recoveryPhrase, differentMnemonic)
    }

    func test_restore_isDeterministic() async throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let first = try await repo.restore(mnemonic: mnemonic)

        try await repo.wipe()
        let second = try await repo.restore(mnemonic: mnemonic)

        XCTAssertEqual(first, second, "same mnemonic must derive the same identity")
    }

    func test_restore_rejectsInvalidMnemonic() async throws {
        do {
            _ = try await repo.restore(mnemonic: "not a valid mnemonic at all")
            XCTFail("expected invalidMnemonic")
        } catch IdentityError.invalidMnemonic {
            // expected
        }
    }

    // MARK: - Entropy-derived IdentityID

    /// The restore bug in one test. Chats and messages are owner-scoped,
    /// so if importing a phrase minted a new `IdentityID` the restored
    /// archive belonged to an identity that no longer existed on the
    /// device: the summary counted "1 chats, 50 messages" and the chat
    /// list stayed empty, across restarts. The ID must survive a wipe and
    /// a re-import of the same phrase.
    func test_restore_sameMnemonicYieldsSameIdentityID() async throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        _ = try await repo.restore(mnemonic: mnemonic)
        let first = try await selectedID()

        try await repo.wipe()
        _ = try await repo.restore(mnemonic: mnemonic)
        let second = try await selectedID()

        XCTAssertEqual(first, second,
                       "re-importing a recovery phrase must land on the identity that owns the backed-up rows")
    }

    func test_restore_differentMnemonicsYieldDifferentIdentityIDs() async throws {
        _ = try await repo.restore(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
        let first = try await selectedID()

        try await repo.wipe()
        _ = try await repo.restore(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let second = try await selectedID()

        XCTAssertNotEqual(first, second,
                          "two phrases must not collide onto one identity slot")
    }

    /// A freshly-generated identity is derived too — it is the identity
    /// someone re-imports from a recovery phrase later, and that import
    /// has to find it.
    func test_bootstrap_generatedIdentityIsReachableByItsOwnPhrase() async throws {
        let generated = try await repo.bootstrap()
        let id = try await selectedID()
        let phrase = try XCTUnwrap(generated.recoveryPhrase)

        try await repo.wipe()
        _ = try await repo.restore(mnemonic: phrase)

        let reimported = await repo.currentSelectedID()
        XCTAssertEqual(reimported, id,
                       "an identity minted today must be restorable from its own phrase tomorrow")
    }

    /// Adding a phrase the device already holds resolves to the ID it is
    /// already stored under. It must return that identity, not append a
    /// duplicate `orderedIDs` entry that doubles every broadcast summary.
    func test_add_sameMnemonicTwice_doesNotDuplicateTheIdentity() async throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let first = try await repo.add(mnemonic: mnemonic)
        let second = try await repo.add(mnemonic: mnemonic)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try keychain.list().count, 1,
                       "one phrase is one identity, however many times it is imported")
        let summaries = try await repo.currentIdentities()
        XCTAssertEqual(summaries.count, 1)
    }

    /// **No migration, on purpose.** Identities that already exist on a
    /// device keep the random UUID they were persisted under — this change
    /// derives IDs at mint time and rewrites nothing. Loading must
    /// therefore hand back the stored ID untouched, even though its
    /// entropy would now derive a different one. The visible consequence
    /// is stated in the PR: a backup taken by a pre-existing identity
    /// still will not restore after a re-import. Assert the property
    /// rather than assume it, because a well-meaning "fix up the ID on
    /// load" would silently orphan every row already keyed to the old one.
    func test_load_preexistingIdentity_keepsItsPersistedRandomID() async throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let entropy = try XCTUnwrap(Bip39.entropyFromMnemonic(mnemonic))
        let legacyID = IdentityID()  // what the old code minted: random, unrelated to the entropy
        XCTAssertNotEqual(legacyID, IdentityID(derivedFromEntropy: entropy))

        let seed = Bip39.seedFromMnemonic(mnemonic)
        try keychain.write(legacyID, StoredSnapshot(
            name: "Legacy",
            entropy: entropy,
            nostrSecretKey: Bip39.deriveNostrKey(from: seed),
            blsSecretKey: Bip39.deriveBlsKey(from: seed)
        ))

        let freshRepo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: .inMemory(initiallySet: true),
            protectedData: .always
        )
        _ = try await freshRepo.bootstrap()

        let loadedID = await freshRepo.currentSelectedID()
        XCTAssertEqual(loadedID, legacyID,
                       "an already-persisted identity must not be re-keyed under it")
        XCTAssertEqual(try keychain.list(), [legacyID],
                       "no migration: nothing is rewritten under the derived ID")
    }

    // MARK: - wipe

    func test_wipe_clearsKeychainAndCurrentIdentity() async throws {
        _ = try await repo.bootstrap()
        try await repo.wipe()

        let current = await repo.currentIdentity()
        XCTAssertNil(current)
        XCTAssertEqual(try keychain.list(), [],
                       "wipe must clear every per-identity keychain item")
    }

    // MARK: - snapshots

    func test_snapshots_yieldsCurrentValueImmediatelyOnSubscribe() async throws {
        let identity = try await repo.bootstrap()

        var iterator = repo.snapshots.makeAsyncIterator()
        let next = await iterator.next()
        let first = try XCTUnwrap(next)
        XCTAssertEqual(first, identity)
    }

    func test_snapshots_yieldsAfterEveryMutation() async throws {
        let collector = SnapshotCollector()
        let collectorTask = Task {
            for await snap in repo.snapshots {
                await collector.append(snap)
                if await collector.count >= 4 { break }
            }
        }

        // Give the subscribe Task a beat to register the continuation before
        // we start mutating.
        try await Task.sleep(nanoseconds: 50_000_000)

        let generated = try await repo.bootstrap()
        let restored = try await repo.restore(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
        try await repo.wipe()

        await collectorTask.value
        let observed = await collector.snapshots
        XCTAssertEqual(observed, [nil, generated, restored, nil])
    }

    // MARK: - rename

    func test_rename_inactiveIdentity_persistsAcrossFreshRepoAndKeysUnchanged() async throws {
        _ = try await repo.bootstrap()
        let bootstrappedID = await repo.currentSelectedID()
        let firstID = try XCTUnwrap(bootstrappedID)
        let secondID = try await repo.add(name: "Work")
        // Per iOS `add` semantics the new identity does NOT auto-select.
        // Switch to it explicitly so `firstID` is the *inactive* one we
        // rename below.
        try await repo.select(secondID)

        // Snapshot the active Identity bytes BEFORE rename so we can
        // prove a name-only edit doesn't trigger re-derivation.
        let beforeIdentity = await repo.currentIdentity()
        let activeBefore = try XCTUnwrap(beforeIdentity)

        try await repo.rename(firstID, newName: "Personal")

        let summaries = try await repo.currentIdentities()
        XCTAssertEqual(summaries.first { $0.id == firstID }?.name, "Personal")
        XCTAssertEqual(summaries.first { $0.id == secondID }?.name, "Work")
        let selected = await repo.currentSelectedID()
        XCTAssertEqual(selected, secondID,
                       "active selection unchanged by rename")

        let afterIdentity = await repo.currentIdentity()
        let activeAfter = try XCTUnwrap(afterIdentity)
        XCTAssertEqual(activeBefore, activeAfter,
                       "rename must not re-derive any keypair bytes")

        // Survives a full reload from disk.
        let freshRepo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: .inMemory(initiallySet: true),
            protectedData: .always
        )
        _ = try await freshRepo.bootstrap()
        let reloaded = try await freshRepo.currentIdentities()
        XCTAssertEqual(reloaded.first { $0.id == firstID }?.name, "Personal")
        XCTAssertEqual(reloaded.first { $0.id == secondID }?.name, "Work")
    }

    func test_rename_trimsWhitespace() async throws {
        let id = try await repo.add(name: "Original")
        try await repo.rename(id, newName: "  Padded   ")
        let summaries = try await repo.currentIdentities()
        XCTAssertEqual(summaries.first { $0.id == id }?.name, "Padded")
    }

    func test_rename_blankInput_isNoOp() async throws {
        let id = try await repo.add(name: "Keep")
        try await repo.rename(id, newName: "   ")
        try await repo.rename(id, newName: "")
        let summaries = try await repo.currentIdentities()
        XCTAssertEqual(summaries.first { $0.id == id }?.name, "Keep")
    }

    func test_rename_unknownId_throws() async throws {
        _ = try await repo.bootstrap()
        do {
            try await repo.rename(IdentityID(), newName: "Whatever")
            XCTFail("expected identityNotLoaded")
        } catch IdentityError.identityNotLoaded {
            // expected
        }
    }

    func test_snapshots_supportsMultipleConcurrentSubscribers() async throws {
        let a = SnapshotCollector()
        let b = SnapshotCollector()

        let taskA = Task {
            for await snap in repo.snapshots {
                await a.append(snap)
                if await a.count >= 2 { break }
            }
        }
        let taskB = Task {
            for await snap in repo.snapshots {
                await b.append(snap)
                if await b.count >= 2 { break }
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let identity = try await repo.bootstrap()

        await taskA.value
        await taskB.value

        let aSnaps = await a.snapshots
        let bSnaps = await b.snapshots
        XCTAssertEqual(aSnaps, [nil, identity])
        XCTAssertEqual(bSnaps, [nil, identity])
    }

    // MARK: - Helpers

    /// `currentSelectedID()` is actor-isolated and `XCTUnwrap` takes an
    /// autoclosure, which can't await — hop once here so the ID assertions
    /// stay one line each.
    private func selectedID(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> IdentityID {
        let id = await repo.currentSelectedID()
        return try XCTUnwrap(id, "no identity is selected", file: file, line: line)
    }
}

private actor SnapshotCollector {
    var snapshots: [Identity?] = []
    var count: Int { snapshots.count }
    func append(_ snap: Identity?) { snapshots.append(snap) }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
