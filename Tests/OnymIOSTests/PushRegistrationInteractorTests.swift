import CryptoKit
import XCTest
@testable import OnymPush

/// Reconciliation behavior: the interactor should call the backend
/// exactly when something it registered would change, and stay silent
/// otherwise — silence is a privacy property here, not a nicety.
final class PushRegistrationInteractorTests: XCTestCase {
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuite = "push-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private struct StubSigner: PushSigner {
        let key = Curve25519.Signing.PrivateKey()
        func userKeyID() async throws -> String {
            "onym:key:" + key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        }
        func sign(_ message: Data) async throws -> Data {
            try key.signature(for: message)
        }
    }

    private struct NoAttestation: PushDeviceAttestationProvider {
        func currentToken() async -> Data? { nil }
    }

    private func makeInteractor(
        client: StubPushBackendClient,
        preferences: PushPreferenceStore,
        signer: StubSigner = StubSigner(),
        refreshInterval: TimeInterval = 7 * 24 * 3600,
        clock: @escaping @Sendable () -> Date = Date.init
    ) -> PushRegistrationInteractor {
        PushRegistrationInteractor(
            client: client,
            signer: signer,
            attestation: NoAttestation(),
            preferences: preferences,
            debounce: .milliseconds(20),
            refreshInterval: refreshInterval,
            clock: clock
        )
    }

    private func makePreferences(enabled: Bool) -> PushPreferenceStore {
        let suite = defaultsSuite!
        let store = PushPreferenceStore(defaults: { UserDefaults(suiteName: suite)! })
        store.setEnabled(enabled)
        return store
    }

    /// Deadline-polls instead of sleeping a fixed interval: the
    /// debounce is 20ms, so the expected state usually lands within a
    /// poll or two, and a genuinely stuck condition fails loudly.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition never became true within \(timeout)", file: file, line: line)
    }

    /// For asserting that nothing happens: enough time for the 20ms
    /// debounce plus a would-be call to land, kept short because it is
    /// pure waiting — a positive expectation should use `waitUntil`.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    func testRegistersOnceTokenAndSubscriptionsAreKnown() async throws {
        let client = StubPushBackendClient()
        let interactor = makeInteractor(client: client, preferences: makePreferences(enabled: true))
        let subs = [PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])]

        await interactor.updateToken(Data([0x01, 0x02]))
        await interactor.updateSubscriptions(subs)
        try await waitUntil { await client.registered.count == 1 }

        let registered = await client.registered
        XCTAssertEqual(registered.first?.subscriptions, subs)
        // The attestation stub has no token; the request must say so
        // rather than fabricate one.
        XCTAssertNil(registered.first?.deviceToken)
    }

    func testDisabledPreferenceMeansNoCallAtAll() async throws {
        let client = StubPushBackendClient()
        let interactor = makeInteractor(client: client, preferences: makePreferences(enabled: false))

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://r.example"])])
        try await settle()

        let registered = await client.registered
        XCTAssertTrue(registered.isEmpty)
    }

    func testUnchangedStateIsNotReRegistered() async throws {
        let client = StubPushBackendClient()
        let interactor = makeInteractor(client: client, preferences: makePreferences(enabled: true))
        let subs = [PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])]

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions(subs)
        try await waitUntil { await client.registered.count == 1 }
        // Same inputs again — the fingerprint matches, nothing is sent.
        await interactor.updateSubscriptions(subs)
        await interactor.appForegrounded()
        try await settle()

        let registered = await client.registered
        XCTAssertEqual(registered.count, 1)
    }

    func testChangedSubscriptionsReRegister() async throws {
        let client = StubPushBackendClient()
        let interactor = makeInteractor(client: client, preferences: makePreferences(enabled: true))

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }
        await interactor.updateSubscriptions([
            PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"]),
            PushSubscription(tag: "00ff00ff00ff00ff", relays: ["wss://nostr.onym.app"]),
        ])
        try await waitUntil { await client.registered.count == 2 }

        let registered = await client.registered
        XCTAssertEqual(registered.last?.subscriptions.count, 2)
    }

    func testFailedRegistrationIsRetriedOnNextTrigger() async throws {
        let client = StubPushBackendClient(
            registerAnswer: .failure(PushClientError.invalidResponse)
        )
        let interactor = makeInteractor(client: client, preferences: makePreferences(enabled: true))
        let subs = [PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])]

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions(subs)
        try await waitUntil { await client.registered.count == 1 }
        // The failure recorded no fingerprint, so the next opportunity
        // tries again — this time succeeding.
        await client.setRegisterAnswer(.success(PushRegisterResponse(expiresAt: .distantFuture)))
        await interactor.appForegrounded()
        try await waitUntil { await client.registered.count == 2 }
    }

    func testDisableUnregistersWithTheKnownToken() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x0a, 0x0b]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }
        XCTAssertNotNil(preferences.lastRegistrationFingerprint)

        // Deliberately NOT `setEnabled(false)` first: that call clears
        // the fingerprint itself, which would make the assertion below
        // pass vacuously. `pushDisabled()` must clear it on its own.
        await interactor.pushDisabled()

        let unregistered = await client.unregistered
        XCTAssertEqual(unregistered.count, 1)
        XCTAssertNil(preferences.lastRegistrationFingerprint)
        // The successful unregister leaves nothing pending and no
        // stale token to fall back to.
        XCTAssertTrue(preferences.pendingUnregisterTokens.isEmpty)
        XCTAssertNil(preferences.lastRegisteredToken)

        preferences.setEnabled(false)
    }

    /// One offline opt-out must not leave the device registered on the
    /// server: the intent persists past the failure and drains at the
    /// next reconcile opportunity.
    func testOfflineDisablePersistsPendingUnregisterAndDrainsOnForeground() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x0a, 0x0b]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }

        await client.setUnregisterAnswer(.failure(PushClientError.invalidResponse))
        preferences.setEnabled(false)
        await interactor.pushDisabled()

        // The attempt happened, failed, and the intent survived it.
        let afterFailure = await client.unregistered
        XCTAssertEqual(afterFailure.count, 1)
        XCTAssertEqual(preferences.pendingUnregisterTokens, [Data([0x0a, 0x0b])])

        // Next foreground: the pending unregister drains first, and
        // with the preference off nothing re-registers.
        await client.setUnregisterAnswer(.success(()))
        await interactor.appForegrounded()
        try await waitUntil { await client.unregistered.count == 2 }
        XCTAssertTrue(preferences.pendingUnregisterTokens.isEmpty)
        let registered = await client.registered
        XCTAssertEqual(registered.count, 1)
    }

    /// Disabling in a launch where APNs has not (re)delivered the
    /// token falls back to the last successfully registered one — the
    /// register recorded it for exactly this moment.
    func testDisableWithoutLiveTokenFallsBackToTheRecordedOne() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        // One signer for both interactors: a relaunch keeps the same
        // signing identity, and a per-interactor random key would let
        // this test pass even if the fallback token were wrongly
        // derived from signer state rather than from the store.
        let signer = StubSigner()
        let first = makeInteractor(client: client, preferences: preferences, signer: signer)

        await first.updateToken(Data([0x0a, 0x0b]))
        await first.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }
        XCTAssertEqual(preferences.lastRegisteredToken, Data([0x0a, 0x0b]))

        // A fresh interactor — same persisted state, no APNs token yet.
        let second = makeInteractor(client: client, preferences: preferences, signer: signer)
        preferences.setEnabled(false)
        await second.pushDisabled()

        let unregistered = await client.unregistered
        XCTAssertEqual(unregistered.count, 1)
        XCTAssertTrue(preferences.pendingUnregisterTokens.isEmpty)
        // Same signer, so the unregister names the same userKey the
        // register did — the relaunch scenario as it actually is.
        let registered = await client.registered
        XCTAssertEqual(unregistered.first?.userKey, registered.first?.userKey)
    }

    func testRegisterRecordsExpiry() async throws {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let client = StubPushBackendClient(
            registerAnswer: .success(PushRegisterResponse(expiresAt: expires))
        )
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { preferences.registrationExpiresAt == expires }
    }

    /// The backend's own expiry drives the refresh: an unchanged
    /// registration re-registers once `now` is inside the expiry
    /// margin, even though the fixed interval has not elapsed (it is
    /// set far away here to isolate the expiry path).
    func testNearExpiryReRegistersDespiteUnchangedInputs() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ClockBox(start)
        // A 10-day window: the margin is min(7d, window/2) = 5 days.
        let client = StubPushBackendClient(
            registerAnswer: .success(
                PushRegisterResponse(expiresAt: start.addingTimeInterval(10 * 24 * 3600))
            )
        )
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(
            client: client,
            preferences: preferences,
            refreshInterval: 365 * 24 * 3600,
            clock: { clock.now }
        )

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }

        // Four days in — still a day outside the margin: quiet.
        clock.now = start.addingTimeInterval(4 * 24 * 3600)
        await interactor.appForegrounded()
        try await settle()
        var registered = await client.registered
        XCTAssertEqual(registered.count, 1)

        // Six days in — inside the 5-day margin: re-register.
        clock.now = start.addingTimeInterval(6 * 24 * 3600)
        await interactor.appForegrounded()
        try await waitUntil { await client.registered.count == 2 }
        registered = await client.registered
        XCTAssertEqual(registered.count, 2)
    }

    /// A backend window shorter than twice the fixed margin must not
    /// make "already registered" unsatisfiable — the margin derives
    /// from the window, so a fresh registration under a 3-day window
    /// stays quiet instead of re-registering (and spending a
    /// signature) at every foreground.
    func testShortExpiryWindowDoesNotChurn() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = StubPushBackendClient(
            registerAnswer: .success(
                PushRegisterResponse(expiresAt: now.addingTimeInterval(3 * 24 * 3600))
            )
        )
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences, clock: { now })

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }
        await interactor.appForegrounded()
        try await settle()

        let registered = await client.registered
        XCTAssertEqual(registered.count, 1)
    }

    /// A *degenerate* window — `expiresAt` at (or behind) the moment
    /// of registration — must not make "already registered"
    /// unsatisfiable either: below the one-hour floor the grant is
    /// ignored entirely and the fixed interval alone paces, so a
    /// foreground stays quiet instead of re-registering (and spending
    /// a signature) every single time.
    func testDegenerateExpiryWindowDoesNotChurn() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = StubPushBackendClient(
            registerAnswer: .success(PushRegisterResponse(expiresAt: now))
        )
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences, clock: { now })

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }
        await interactor.appForegrounded()
        try await settle()

        let registered = await client.registered
        XCTAssertEqual(registered.count, 1)
    }

    /// The fixed interval alone forces a refresh: with `expiresAt`
    /// far away, an unchanged registration still re-registers once the
    /// interval has elapsed, so the backend's 60-day sweep never reaps
    /// a live device.
    func testElapsedRefreshIntervalReRegisters() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences, refreshInterval: 0)

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }
        await interactor.appForegrounded()
        try await waitUntil { await client.registered.count == 2 }
    }

    /// An empty subscription list is meaningful: it registers (clears
    /// every tag at the backend) rather than being treated as "nothing
    /// to say", and the device stays registered.
    func testEmptySubscriptionsRegistersWithNoTags() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }

        await interactor.updateSubscriptions([])
        try await waitUntil { await client.registered.count == 2 }

        let registered = await client.registered
        XCTAssertEqual(registered.last?.subscriptions, [])
        XCTAssertNotNil(preferences.lastRegisteredToken)
        XCTAssertNotNil(preferences.lastRegistrationFingerprint)
        let unregistered = await client.unregistered
        XCTAssertTrue(unregistered.isEmpty)
    }

    /// `pushEnabled()` is itself a reconcile trigger: with inputs
    /// already known but no registration recorded (the preference was
    /// off when they arrived), flipping it on registers.
    func testPushEnabledTriggersReconcile() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: false)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await settle()
        let before = await client.registered
        XCTAssertTrue(before.isEmpty)

        preferences.setEnabled(true)
        await interactor.pushEnabled()
        try await waitUntil { await client.registered.count == 1 }
    }

    /// APNs rotated the token: the backend keys registrations by token
    /// hash, so the old row must be unregistered rather than left
    /// wake-able until the 60-day sweep.
    func testTokenRotationUnregistersThePreviousToken() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x0a, 0x0b]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }

        await interactor.updateToken(Data([0x0c, 0x0d]))
        try await waitUntil { await client.registered.count == 2 }
        try await waitUntil { await client.unregistered.count == 1 }

        XCTAssertTrue(preferences.pendingUnregisterTokens.isEmpty)
        XCTAssertEqual(preferences.lastRegisteredToken, Data([0x0c, 0x0d]))
    }

    /// The dropped-token scenario from review: a rotation whose drain
    /// failed (old token still owed) followed by a disable (new token
    /// now owed too) is *two* debts — the old single-slot store kept
    /// only the newer one and the old token stayed wake-able until the
    /// backend's 60-day sweep. Both must survive and both must drain.
    func testRotationDebtAndDisableDebtBothDrain() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x0a]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { await client.registered.count == 1 }

        // Rotation with the unregister path down: A's debt persists
        // past the failed drain while B registers.
        await client.setUnregisterAnswer(.failure(PushClientError.invalidResponse))
        await interactor.updateToken(Data([0x0b]))
        try await waitUntil { await client.registered.count == 2 }
        XCTAssertEqual(preferences.pendingUnregisterTokens, [Data([0x0a])])

        // Disable while A is still owed: B joins the set instead of
        // overwriting A.
        preferences.setEnabled(false)
        await interactor.pushDisabled()
        XCTAssertEqual(
            Set(preferences.pendingUnregisterTokens),
            Set([Data([0x0a]), Data([0x0b])])
        )

        // Network back: one opportunity drains both debts.
        await client.setUnregisterAnswer(.success(()))
        await interactor.appForegrounded()
        try await waitUntil { preferences.pendingUnregisterTokens.isEmpty }
        XCTAssertNil(preferences.lastRegisteredToken)
    }

    /// Swallowed reconcile errors are observable through the test-only
    /// hook: a degenerate (all-zero) registration key makes the seal
    /// refuse, no register reaches the backend, and the failure is
    /// reported rather than silently vanishing.
    func testReconcileFailureHookSeesTheSwallowedError() async throws {
        let client = StubPushBackendClient(
            registrationKeyAnswer: Data(repeating: 0, count: 32)
        )
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        let failures = FailureBox()
        await interactor.setOnReconcileFailure { failures.append($0) }

        await interactor.updateToken(Data([0x01]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await waitUntil { !failures.errors.isEmpty }

        let registered = await client.registered
        XCTAssertTrue(registered.isEmpty)
        XCTAssertEqual(
            failures.errors.first as? PushTokenEnvelope.SealError,
            .invalidServerKey
        )
    }

    /// The reentrancy hole the second review found: a disable landing
    /// while a register is suspended mid-flight must win. The register
    /// still reaches the backend (it was already in transit), but it
    /// is never recorded as live, and the pending unregister both
    /// survives it and drains after it — the backend ends the episode
    /// forgotten, not registered behind the user's back.
    func testDisableDuringInFlightRegisterEndsUnregistered() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        let gate = TestGate()
        let inFlight = TestGate()
        await client.setOnRegister {
            inFlight.open()
            await gate.wait()
        }

        await interactor.updateToken(Data([0x0a, 0x0b]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        // Hold until the register is suspended inside the client.
        await inFlight.wait()

        // The disable interleaves: it must not spend a second
        // signature concurrently — it queues behind the in-flight
        // pass and returns.
        preferences.setEnabled(false)
        await interactor.pushDisabled()
        let beforeLanding = await client.unregistered
        XCTAssertTrue(beforeLanding.isEmpty)
        XCTAssertEqual(preferences.pendingUnregisterTokens, [Data([0x0a, 0x0b])])

        // Let the register land — after the unregister intent.
        await client.setOnRegister(nil)
        gate.open()
        try await waitUntil { await client.unregistered.count == 1 }

        // Nothing recorded as registered, nothing left pending: the
        // register that landed late was superseded and torn down.
        XCTAssertNil(preferences.lastRegistrationFingerprint)
        XCTAssertTrue(preferences.pendingUnregisterTokens.isEmpty)
        let registered = await client.registered
        XCTAssertEqual(registered.count, 1)
    }
}

/// A mutable now the test can advance; the interactor's clock closure
/// reads it. Locked because the closure is `@Sendable`.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); defer { lock.unlock() }; date = newValue }
    }
}

/// Collects errors from the `@Sendable` failure hook.
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Error] = []
    func append(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        stored.append(error)
    }
    var errors: [Error] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// A reusable one-shot gate for holding an async call open.
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let resumed = waiters
        waiters = []
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }
}
