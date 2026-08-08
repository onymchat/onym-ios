import XCTest
@testable import OnymModeration

/// Consent lifecycle: manifest hash pinning to fetched bytes, mandate
/// immutability across authority switches, the stub's honesty
/// guarantees, and the never-fabricate-a-token rule.
final class ModerationRepositoryTests: XCTestCase {

    // MARK: - Fakes

    private struct FakeAuthoritiesFetcher: KnownAuthoritiesFetcher {
        let listings: [AuthorityListing]
        func fetchLatest() async throws -> [AuthorityListing] { listings }
    }

    private struct FakeManifestFetcher: AuthorityManifestFetcher {
        /// Raw manifest bytes per componentId — returned verbatim so
        /// tests control the exact bytes the hash pins.
        let bytesByComponent: [String: Data]

        func fetch(_ listing: AuthorityListing) async throws -> SignedManifest {
            guard let bytes = bytesByComponent[listing.componentId] else {
                throw ModerationError.manifestInvalid("no fixture")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(AuthorityManifest.self, from: bytes)
            return SignedManifest(manifest: manifest, rawBytes: bytes)
        }
    }

    private final class InMemoryMandateStore: MandateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [MandateRecord] = []
        func load() -> [MandateRecord] { lock.withLock { records } }
        func save(_ records: [MandateRecord]) { lock.withLock { self.records = records } }
    }

    /// Records every request so tests can assert what the client
    /// actually presented (tokens, signatures).
    private final class RecordingBackend: EnforcementBackendClient, @unchecked Sendable {
        private let lock = NSLock()
        var enrollTokens: [Data?] { lock.withLock { _enrollTokens } }
        var gateRequests: [GateCheckRequest] { lock.withLock { _gateRequests } }
        private var _enrollTokens: [Data?] = []
        private var _gateRequests: [GateCheckRequest] = []
        var gateResult: GateCheckResult = .clear

        func enrollDevice(token: Data?, userKey: String, signature: Data) async throws -> DeviceEnrollment {
            lock.withLock { _enrollTokens.append(token) }
            return DeviceEnrollment(deviceBinding: "recorded-enrollment")
        }

        func countersignMandate(_ mandate: ModerationMandate) async throws -> ModerationMandate {
            var countersigned = mandate
            countersigned.signatures.append(StubEnforcementBackendClient.countersignSentinel)
            return countersigned
        }

        func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult {
            lock.withLock { _gateRequests.append(request) }
            return gateResult
        }
    }

    private struct FakeAttestation: DeviceAttestationProvider {
        let supported: Bool
        var isSupported: Bool { supported }
        func generateToken() async throws -> Data {
            guard supported else { throw ModerationError.attestationUnavailable }
            return Data("fake-token".utf8)
        }
    }

    private struct FakeSigner: ModerationSigner {
        func userKeyID() async throws -> String { "onym:key:test-user" }
        func sign(_ message: Data) async throws -> Data { Data("fake-signature".utf8) }
    }

    // MARK: - Fixtures

    private func manifestBytes(componentId: String, tweak: String = "") -> Data {
        Data("""
        {
          "version": 1,
          "componentId": "\(componentId)",
          "seat": "moderation",
          "operator": "onym:key:operator",
          "moderationProfileId": "onym:moderation-profile:consent-bound-v1",
          "violationClasses": [
            {
              "classId": "csam",
              "definition": "hash:csam-def\(tweak)",
              "responseWindow": "P3D",
              "decisionDeadline": "P7D",
              "banTerm": "permanent",
              "appealWindow": "P30D",
              "appealEffect": "non-suspensive"
            }
          ],
          "appellate": "onym:component:appellate",
          "validUntil": "2030-01-01T00:00:00Z",
          "signature": "unsigned-fixture"
        }
        """.utf8)
    }

    private func listing(_ componentId: String, name: String) -> AuthorityListing {
        AuthorityListing(
            componentId: componentId,
            name: name,
            manifestURL: URL(string: "https://example.com/\(name).json")!,
            operatorPublicKeyBase64: ""
        )
    }

    private func makeRepository(
        listings: [AuthorityListing],
        bytesByComponent: [String: Data],
        backend: any EnforcementBackendClient,
        attestation: any DeviceAttestationProvider = FakeAttestation(supported: true),
        store: MandateStore? = nil
    ) -> ModerationRepository {
        ModerationRepository(
            authoritiesFetcher: FakeAuthoritiesFetcher(listings: listings),
            manifestFetcher: FakeManifestFetcher(bytesByComponent: bytesByComponent),
            mandateStore: store ?? InMemoryMandateStore(),
            backend: backend,
            attestation: attestation,
            signer: FakeSigner(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    // MARK: - Consent pins fetched bytes

    func testConsentPinsHashOfExactFetchedBytes() async throws {
        let componentId = "onym:component:a"
        let bytes = manifestBytes(componentId: componentId)
        let repository = makeRepository(
            listings: [listing(componentId, name: "A")],
            bytesByComponent: [componentId: bytes],
            backend: RecordingBackend()
        )

        let record = try await repository.consent(to: listing(componentId, name: "A"))

        XCTAssertEqual(record.manifestBytes, bytes)
        XCTAssertEqual(record.mandate.manifestHash, SignedManifest.hash(of: bytes))
        XCTAssertEqual(record.mandate.user, "onym:key:test-user")
        XCTAssertEqual(record.mandate.deviceBinding, "recorded-enrollment")
        XCTAssertEqual(record.mandate.classes, ["csam"])
        XCTAssertTrue(record.isActive)
        // The consented snapshot must decode standalone (renders
        // offline, survives the authority disappearing).
        XCTAssertNotNil(record.consentedManifest())
    }

    // MARK: - Switching immutability

    func testSwitchingDeactivatesOldRecordUntouched() async throws {
        let aID = "onym:component:a"
        let bID = "onym:component:b"
        let aBytes = manifestBytes(componentId: aID)
        let bBytes = manifestBytes(componentId: bID, tweak: "-b")
        let store = InMemoryMandateStore()
        let repository = makeRepository(
            listings: [listing(aID, name: "A"), listing(bID, name: "B")],
            bytesByComponent: [aID: aBytes, bID: bBytes],
            backend: RecordingBackend(),
            store: store
        )

        let first = try await repository.consent(to: listing(aID, name: "A"))
        let second = try await repository.consent(to: listing(bID, name: "B"))

        let records = store.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.mandate.authority, bID)
        XCTAssertTrue(second.isActive)

        // The deactivated record is byte-identical apart from the
        // active flag — mandates are immutable (spec §12).
        let deactivated = try XCTUnwrap(records.first { $0.mandate.authority == aID })
        XCTAssertFalse(deactivated.isActive)
        XCTAssertEqual(deactivated.mandate, first.mandate)
        XCTAssertEqual(deactivated.manifestBytes, aBytes)
        XCTAssertEqual(deactivated.mandate.manifestHash, SignedManifest.hash(of: aBytes))

        let active = await repository.activeMandateRecord()
        XCTAssertEqual(active?.mandate.authority, bID)
    }

    // MARK: - Stub honesty

    func testStubCountersignSentinelNeverReadsAsCountersigned() async throws {
        let componentId = "onym:component:a"
        let repository = makeRepository(
            listings: [listing(componentId, name: "A")],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: RecordingBackend()  // appends the stub sentinel
        )

        let record = try await repository.consent(to: listing(componentId, name: "A"))

        XCTAssertFalse(record.countersigned)
        XCTAssertEqual(record.mandate.signatures.count, 2)
        XCTAssertEqual(record.mandate.signatures.last, StubEnforcementBackendClient.countersignSentinel)
    }

    func testStubEnrollmentBindingIsStableAcrossCalls() async throws {
        let suite = "stub-backend-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = StubEnforcementBackendClient(defaults: defaults)

        let first = try await stub.enrollDevice(token: nil, userKey: "u", signature: Data())
        let second = try await stub.enrollDevice(token: Data("t".utf8), userKey: "u", signature: Data())
        XCTAssertEqual(first.deviceBinding, second.deviceBinding)
    }

    // MARK: - Never fabricate a token

    func testUnsupportedAttestationEnrollsWithNilToken() async throws {
        let componentId = "onym:component:a"
        let backend = RecordingBackend()
        let repository = makeRepository(
            listings: [listing(componentId, name: "A")],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            attestation: FakeAttestation(supported: false)
        )

        _ = try await repository.consent(to: listing(componentId, name: "A"))

        XCTAssertEqual(backend.enrollTokens, [nil])
    }

    func testGateCheckPassesNilTokenThroughAndBlocksOnCheckRequired() async throws {
        let componentId = "onym:component:a"
        let backend = RecordingBackend()
        backend.gateResult = .checkRequired(.attestationUnavailable)
        let moderation = makeRepository(
            listings: [listing(componentId, name: "A")],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            attestation: FakeAttestation(supported: false)
        )
        _ = try await moderation.consent(to: listing(componentId, name: "A"))

        let gate = GateCheckRepository(
            attestation: FakeAttestation(supported: false),
            backend: backend,
            moderation: moderation,
            signer: FakeSigner(),
            store: InMemoryGateStateStore(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        await gate.checkNow()

        XCTAssertEqual(backend.gateRequests.count, 1)
        XCTAssertNil(backend.gateRequests.first?.deviceToken)
        let status = await gate.currentStatus()
        XCTAssertEqual(status, .gateCheckRequired(.attestationUnavailable))
    }

    func testGateCheckIsNotMandatedWithoutActiveMandate() async throws {
        let backend = RecordingBackend()
        let moderation = makeRepository(
            listings: [],
            bytesByComponent: [:],
            backend: backend
        )
        let gate = GateCheckRepository(
            attestation: FakeAttestation(supported: true),
            backend: backend,
            moderation: moderation,
            signer: FakeSigner(),
            store: InMemoryGateStateStore(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        await gate.checkNow()

        // No mandate → no backend calls at all (the protocol stays
        // usable pre-consent; only this interface requires a mandate).
        XCTAssertTrue(backend.gateRequests.isEmpty)
        let status = await gate.currentStatus()
        XCTAssertEqual(status, .notMandated)
    }

    private final class InMemoryGateStateStore: GateStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: PersistedGateState?
        func load() -> PersistedGateState? { lock.withLock { state } }
        func save(_ state: PersistedGateState?) { lock.withLock { self.state = state } }
    }
}
