import XCTest
@testable import OnymIOS
@testable import OnymIdentity

/// `reconcileFreshInstall()` — the launch-time verdict that decides
/// whether keychain identities are orphans of a deleted install. The
/// wrong verdict used to destroy key material; it now quarantines, and
/// these tests pin every branch: fresh install, app update, normal
/// launch, and the deferred pre-first-unlock case.
final class IdentityRepositoryFreshInstallTests: XCTestCase {
    private var keychain: IdentityKeychainStore!

    override func setUp() {
        super.setUp()
        keychain = IdentityKeychainStore(
            testNamespace: "fresh-\(UUID().uuidString)"
        )
    }

    override func tearDown() {
        try? keychain.wipeAll()
        keychain = nil
        super.tearDown()
    }

    /// No marker, no selection → fresh install: keychain leftovers are
    /// quarantined (never destroyed) and bootstrap mints a new identity.
    func test_freshInstall_quarantinesOrphansAndMintsNewIdentity() async throws {
        let orphans = try await seedIdentities()

        let repo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: .inMemory(initiallySet: false),
            protectedData: .always
        )
        let minted = try await repo.bootstrap()

        let active = try await repo.currentIdentities()
        XCTAssertEqual(active.count, 1, "only the freshly-minted identity is active")
        XCTAssertFalse(orphans.contains(minted.blsPublicKey),
                       "the minted identity is new, not a resurrected orphan")
        XCTAssertEqual(try keychain.list().count, 1,
                       "orphans are out of the active namespace")
        XCTAssertEqual(try keychain.listQuarantined().count, 2,
                       "orphans are quarantined — key material preserved, never wiped")
    }

    /// No marker but a persisted selection → app update predating the
    /// marker: everything is kept and the marker is stamped.
    func test_appUpdate_keepsIdentitiesAndStampsMarker() async throws {
        _ = try await seedIdentities()
        let selected = try keychain.list().first
        let marker = InstallMarker.inMemory(initiallySet: false)

        let repo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(initial: selected),
            installMarker: marker,
            protectedData: .always
        )
        _ = try await repo.bootstrap()

        let active = try await repo.currentIdentities()
        XCTAssertEqual(active.count, 2, "an app update must keep every identity")
        XCTAssertEqual(try keychain.listQuarantined(), [])
        XCTAssertTrue(marker.exists(), "the update launch stamps the marker")
    }

    /// Marker present → normal launch, reconcile is a no-op.
    func test_markerPresent_keepsIdentities() async throws {
        _ = try await seedIdentities()

        let repo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: .inMemory(initiallySet: true),
            protectedData: .always
        )
        _ = try await repo.bootstrap()

        let active = try await repo.currentIdentities()
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(try keychain.listQuarantined(), [])
    }

    /// Protected data unavailable (pre-first-unlock launch): the
    /// fresh-install signals are unreadable, so the verdict is
    /// deferred — nothing quarantined, marker left unstamped so a
    /// later unlocked launch re-runs the reconcile with real inputs.
    func test_protectedDataUnavailable_defersReconcile() async throws {
        _ = try await seedIdentities()
        let marker = InstallMarker.inMemory(initiallySet: false)

        let locked = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: marker,
            protectedData: ProtectedDataAvailability(isAvailable: { false })
        )
        _ = try await locked.bootstrap()

        let active = try await locked.currentIdentities()
        XCTAssertEqual(active.count, 2,
                       "no verdict while the signals are unreadable — identities stay")
        XCTAssertEqual(try keychain.listQuarantined(), [])
        XCTAssertFalse(marker.exists(),
                       "the marker must not be stamped off unreadable inputs")

        // Next launch, device unlocked: the deferred verdict lands.
        let unlocked = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: marker,
            protectedData: .always
        )
        _ = try await unlocked.bootstrap()
        XCTAssertEqual(try keychain.listQuarantined().count, 2,
                       "the reconcile runs on the first launch that can read its inputs")
        XCTAssertTrue(marker.exists())
    }

    /// Regression: the protected-data check suspends inside the first
    /// load, and actor reentrancy let two concurrent first-callers
    /// (the app's sibling `bootstrap()` / `currentIdentities()`
    /// launch tasks) interleave across it — appending every identity
    /// twice. The slow availability closure below holds the window
    /// open; the single-flight load must keep the list exact.
    func test_concurrentFirstLoads_doNotDuplicateIdentities() async throws {
        _ = try await seedIdentities()
        let selected = try keychain.list().first

        let repo = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(initial: selected),
            installMarker: .inMemory(initiallySet: false),
            protectedData: ProtectedDataAvailability(isAvailable: {
                try? await Task.sleep(for: .milliseconds(100))
                return true
            })
        )

        async let first = repo.bootstrap()
        async let second = repo.currentIdentities()
        _ = try await first
        _ = try await second

        let summaries = try await repo.currentIdentities()
        XCTAssertEqual(summaries.count, 2,
                       "concurrent first loads must not double-append identities")
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2,
                       "every picker entry is distinct")
    }

    /// Quarantining twice (fresh install verdict on two consecutive
    /// launches) must not throw on the duplicate items.
    func test_quarantineAll_idempotentAcrossRepeatedVerdicts() async throws {
        _ = try await seedIdentities()
        try keychain.quarantineAll()
        _ = try await seedIdentities(names: ["Third"])

        XCTAssertNoThrow(try keychain.quarantineAll())
        XCTAssertEqual(try keychain.list(), [])
        XCTAssertEqual(try keychain.listQuarantined().count, 3)
    }

    // MARK: - Helpers

    /// Seeds identities through a marker-set repo (no reconcile) and
    /// returns their BLS pubkeys for identity comparison.
    private func seedIdentities(names: [String] = ["Personal", "Work"]) async throws -> Set<Data> {
        let seeder = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory(),
            installMarker: .inMemory(initiallySet: true),
            protectedData: .always
        )
        for name in names {
            _ = try await seeder.add(name: name)
        }
        return Set(try await seeder.currentIdentities().map(\.blsPublicKey))
    }
}
