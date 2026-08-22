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
        clock: @escaping @Sendable () -> Date = Date.init
    ) -> PushRegistrationInteractor {
        PushRegistrationInteractor(
            client: client,
            signer: StubSigner(),
            attestation: NoAttestation(),
            preferences: preferences,
            debounce: .milliseconds(20),
            clock: clock
        )
    }

    private func makePreferences(enabled: Bool) -> PushPreferenceStore {
        let suite = defaultsSuite!
        let store = PushPreferenceStore(defaults: { UserDefaults(suiteName: suite)! })
        store.setEnabled(enabled)
        return store
    }

    /// Debounce is 20ms; give reconciliation room to run.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func testRegistersOnceTokenAndSubscriptionsAreKnown() async throws {
        let client = StubPushBackendClient()
        let interactor = makeInteractor(client: client, preferences: makePreferences(enabled: true))
        let subs = [PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])]

        await interactor.updateToken(Data([0x01, 0x02]))
        await interactor.updateSubscriptions(subs)
        try await settle()

        let registered = await client.registered
        XCTAssertEqual(registered.count, 1)
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
        try await settle()
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
        try await settle()
        await interactor.updateSubscriptions([
            PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"]),
            PushSubscription(tag: "00ff00ff00ff00ff", relays: ["wss://nostr.onym.app"]),
        ])
        try await settle()

        let registered = await client.registered
        XCTAssertEqual(registered.count, 2)
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
        try await settle()
        // The failure recorded no fingerprint, so the next opportunity
        // tries again — this time succeeding.
        await client.setRegisterAnswer(.success(PushRegisterResponse(expiresAt: .distantFuture)))
        await interactor.appForegrounded()
        try await settle()

        let registered = await client.registered
        XCTAssertEqual(registered.count, 2)
    }

    func testDisableUnregistersWithTheKnownToken() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let interactor = makeInteractor(client: client, preferences: preferences)

        await interactor.updateToken(Data([0x0a, 0x0b]))
        await interactor.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await settle()

        preferences.setEnabled(false)
        await interactor.pushDisabled()

        let unregistered = await client.unregistered
        XCTAssertEqual(unregistered.count, 1)
        XCTAssertNil(preferences.lastRegistrationFingerprint)
        // The successful unregister leaves nothing pending and no
        // stale token to fall back to.
        XCTAssertNil(preferences.pendingUnregisterToken)
        XCTAssertNil(preferences.lastRegisteredToken)
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
        try await settle()

        await client.setUnregisterAnswer(.failure(PushClientError.invalidResponse))
        preferences.setEnabled(false)
        await interactor.pushDisabled()

        // The attempt happened, failed, and the intent survived it.
        let afterFailure = await client.unregistered
        XCTAssertEqual(afterFailure.count, 1)
        XCTAssertEqual(preferences.pendingUnregisterToken, Data([0x0a, 0x0b]))

        // Next foreground: the pending unregister drains first, and
        // with the preference off nothing re-registers.
        await client.setUnregisterAnswer(.success(()))
        await interactor.appForegrounded()
        try await settle()

        let drained = await client.unregistered
        XCTAssertEqual(drained.count, 2)
        XCTAssertNil(preferences.pendingUnregisterToken)
        let registered = await client.registered
        XCTAssertEqual(registered.count, 1)
    }

    /// Disabling in a launch where APNs has not (re)delivered the
    /// token falls back to the last successfully registered one — the
    /// register recorded it for exactly this moment.
    func testDisableWithoutLiveTokenFallsBackToTheRecordedOne() async throws {
        let client = StubPushBackendClient()
        let preferences = makePreferences(enabled: true)
        let first = makeInteractor(client: client, preferences: preferences)

        await first.updateToken(Data([0x0a, 0x0b]))
        await first.updateSubscriptions([PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])])
        try await settle()
        XCTAssertEqual(preferences.lastRegisteredToken, Data([0x0a, 0x0b]))

        // A fresh interactor — same persisted state, no APNs token yet.
        let second = makeInteractor(client: client, preferences: preferences)
        preferences.setEnabled(false)
        await second.pushDisabled()

        let unregistered = await client.unregistered
        XCTAssertEqual(unregistered.count, 1)
        XCTAssertNil(preferences.pendingUnregisterToken)
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
        try await settle()

        XCTAssertEqual(preferences.registrationExpiresAt, expires)
    }

    /// The backend's own expiry drives the refresh: an unchanged
    /// registration re-registers once `now` is within seven days of
    /// `expiresAt`, even though the fixed interval has not elapsed.
    func testNearExpiryReRegistersDespiteUnchangedInputs() async throws {
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
        try await settle()
        await interactor.appForegrounded()
        try await settle()

        let registered = await client.registered
        XCTAssertEqual(registered.count, 2)
    }
}
