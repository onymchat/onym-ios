import XCTest
@testable import OnymIOS

/// Each test uses its own Keychain service so test runs are isolated and
/// do not collide with the production identity item or with each other.
/// Tests hit the real Keychain (no mocks) — the simulator Keychain is the
/// thing the app actually uses, and a mock here would defeat the point of
/// integration-testing the persistence layer.
final class IdentityRepositoryTests: XCTestCase {
    private var keychain: KeychainStore!
    private var repo: IdentityRepository!

    override func setUp() {
        super.setUp()
        keychain = KeychainStore(
            service: "chat.onym.ios.identity.tests.\(UUID().uuidString)",
            account: "current"
        )
        repo = IdentityRepository(keychain: keychain)
    }

    override func tearDown() {
        try? keychain.wipe()
        keychain = nil
        repo = nil
        super.tearDown()
    }

    // MARK: - bootstrap

    func test_bootstrap_freshInstall_generatesAndPersistsBip39Identity() async throws {
        let identity = try await repo.bootstrap()

        XCTAssertEqual(identity.nostrPublicKey.count, 32)
        XCTAssertEqual(identity.blsPublicKey.count, 48)
        XCTAssertNotNil(identity.recoveryPhrase)
        XCTAssertEqual(identity.recoveryPhrase?.split(separator: " ").count, 12)

        let stored = try keychain.load()
        XCTAssertNotNil(stored, "bootstrap must persist to Keychain")
        XCTAssertEqual(stored?.entropy?.count, 16)
        XCTAssertEqual(stored?.nostrSecretKey.count, 32)
        XCTAssertEqual(stored?.blsSecretKey.count, 32)
    }

    func test_bootstrap_isIdempotent() async throws {
        let first = try await repo.bootstrap()
        let second = try await repo.bootstrap()

        XCTAssertEqual(first, second, "second bootstrap must return the same identity")
    }

    func test_bootstrap_picksUpExistingKeychainItem() async throws {
        let first = try await repo.bootstrap()

        // Fresh repo against the same Keychain — should load, not regenerate.
        let secondRepo = IdentityRepository(keychain: keychain)
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

    // MARK: - wipe

    func test_wipe_clearsKeychainAndCurrentIdentity() async throws {
        _ = try await repo.bootstrap()
        try await repo.wipe()

        let current = await repo.currentIdentity()
        XCTAssertNil(current)
        let stored = try keychain.load()
        XCTAssertNil(stored)
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
}

private actor SnapshotCollector {
    var snapshots: [Identity?] = []
    var count: Int { snapshots.count }
    func append(_ snap: Identity?) { snapshots.append(snap) }
}
