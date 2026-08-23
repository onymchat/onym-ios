import XCTest
@testable import OnymIOS
import OnymIdentity
import OnymPush
import OnymTransportNostr

/// The privacy-load-bearing gate: notification authorization revoked
/// in system Settings while the in-app preference says on means the
/// toggle is a lie and the server still holds a registration — both
/// the cold launch and the foreground hook must run the full disable
/// path. The authorization probe is injected, so these tests drive it
/// directly.
final class PushCoordinatorTests: XCTestCase {
    private var defaultsSuite: String!
    private var keychain: IdentityKeychainStore!
    /// The scene-lifetime `run()` task, hoisted so tearDown can await
    /// its actual completion: `cancel()` alone is asynchronous, and a
    /// still-winding-down task group would race the keychain wipe and
    /// defaults-domain removal below — cross-test bleed dressed as a
    /// flake.
    private var scene: Task<Void, Never>?

    override func setUp() {
        super.setUp()
        defaultsSuite = "push-coordinator-tests-\(UUID().uuidString)"
        keychain = IdentityKeychainStore(testNamespace: defaultsSuite)
    }

    override func tearDown() async throws {
        scene?.cancel()
        _ = await scene?.value
        scene = nil
        UserDefaults(suiteName: defaultsSuite)?
            .removePersistentDomain(forName: defaultsSuite)
        try? keychain?.wipeAll()
        keychain = nil
    }

    private func makePreferences(enabled: Bool) -> PushPreferenceStore {
        let suite = defaultsSuite!
        let store = PushPreferenceStore(defaults: { UserDefaults(suiteName: suite)! })
        store.setEnabled(enabled)
        return store
    }

    private func makeCoordinator(
        preferences: PushPreferenceStore,
        denied: @escaping @Sendable () async -> Bool
    ) -> PushCoordinator {
        PushCoordinator(
            identityRepository: IdentityRepository(
                keychain: keychain,
                selectionStore: .inMemory()
            ),
            relaysRepository: NostrRelaysRepository(
                store: InMemoryNostrRelaysSelectionStore(initial: .empty)
            ),
            client: StubPushBackendClient(),
            preferences: preferences,
            notificationAuthorizationDenied: denied
        )
    }

    /// Cold launch: `.onChange(of: scenePhase)` never fires for the
    /// initial `.active`, so `run()` itself must reconcile with system
    /// Settings — enabled + denied means the full disable path, before
    /// any APNs registration.
    func testRunDisablesWhenAuthorizationWasRevoked() async throws {
        let preferences = makePreferences(enabled: true)
        let coordinator = makeCoordinator(preferences: preferences, denied: { true })

        // run() then observes streams for the scene's life; poll the
        // observable effect. tearDown cancels the task and awaits its
        // completion before wiping shared state.
        scene = Task { await coordinator.run() }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, preferences.isEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(preferences.isEnabled)
    }

    func testForegroundDisablesWhenAuthorizationWasRevoked() async {
        let preferences = makePreferences(enabled: true)
        let coordinator = makeCoordinator(preferences: preferences, denied: { true })

        await coordinator.appForegrounded()

        XCTAssertFalse(preferences.isEnabled)
        XCTAssertFalse(coordinator.registrationPending)
    }

    /// Authorization intact: the gate must NOT disable — the opt-in
    /// survives the foreground reconciliation untouched.
    func testForegroundKeepsAGrantedAuthorizationEnabled() async {
        let preferences = makePreferences(enabled: true)
        let coordinator = makeCoordinator(preferences: preferences, denied: { false })

        await coordinator.appForegrounded()

        XCTAssertTrue(preferences.isEnabled)
    }

    /// Denied but already off: nothing to reconcile, nothing flips.
    func testForegroundWithPushOffIgnoresTheDenial() async {
        let preferences = makePreferences(enabled: false)
        let coordinator = makeCoordinator(preferences: preferences, denied: { true })

        await coordinator.appForegrounded()

        XCTAssertFalse(preferences.isEnabled)
    }

    // MARK: - Relay caps (backend alignment)

    /// The backend refuses registrations over its caps (4 relays per
    /// tag, 8 hosts / 4 URLs-per-host per device); the client
    /// truncates first so a big relay list degrades to the four
    /// highest-priority relays instead of a refused register.
    func testCappedRelaysKeepsShortListsVerbatim() {
        XCTAssertEqual(PushCoordinator.cappedRelays([]), [])
        let two = ["wss://a.example", "wss://b.example"]
        XCTAssertEqual(PushCoordinator.cappedRelays(two), two)
    }

    /// Deterministic priority: the default relay first (the backend
    /// exempts it from capacity caps), then configured order.
    func testCappedRelaysPrefersTheDefaultRelayThenConfiguredOrder() {
        let configured = [
            "wss://a.example", "wss://b.example", "wss://c.example",
            "wss://d.example", PushCoordinator.defaultRelayURL, "wss://e.example",
        ]
        XCTAssertEqual(
            PushCoordinator.cappedRelays(configured),
            [
                PushCoordinator.defaultRelayURL,
                "wss://a.example", "wss://b.example", "wss://c.example",
            ]
        )
    }

    /// A duplicate URL must not burn one of the four slots.
    func testCappedRelaysDeduplicates() {
        XCTAssertEqual(
            PushCoordinator.cappedRelays(
                ["wss://a.example", "wss://a.example", "wss://b.example"]
            ),
            ["wss://a.example", "wss://b.example"]
        )
    }
}
