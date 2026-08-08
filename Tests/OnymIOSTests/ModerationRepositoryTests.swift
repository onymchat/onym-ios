import XCTest
@testable import OnymModeration

/// Consent lifecycle: manifest hash pinning to fetched bytes, mandate
/// immutability across authority switches, the stub's honesty
/// guarantees, and the never-fabricate-a-token rule.
final class ModerationRepositoryTests: XCTestCase {

    /// The instant the fixture repositories' injected clock returns.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

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
        var enrollRequests: [EnrollmentRequest] { lock.withLock { _enrollRequests } }
        var enrollTokens: [Data?] { enrollRequests.map(\.deviceToken) }
        var gateRequests: [GateCheckRequest] { lock.withLock { _gateRequests } }
        private var _enrollRequests: [EnrollmentRequest] = []
        private var _gateRequests: [GateCheckRequest] = []
        var gateResult: GateCheckResult = .clear
        /// When set, `countersignMandate` returns this instead of the
        /// stub sentinel — lets a test assert what the client does with
        /// a backend-supplied signature.
        var countersignature: String = StubEnforcementBackendClient.countersignSentinel

        func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
            lock.withLock { _enrollRequests.append(request) }
            return DeviceEnrollment(deviceBinding: "recorded-enrollment")
        }

        func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
            InterfaceCountersignature(signature: lock.withLock { countersignature })
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
          "newHolderAppeal": "hash:new-holder",
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

    /// Serves one set of bytes on the first fetch and different bytes
    /// afterwards — an authority editing its hosted terms between the
    /// user's review and their agreement.
    private final class SwitchingManifestFetcher: AuthorityManifestFetcher, @unchecked Sendable {
        private let lock = NSLock()
        private var fetchCount = 0
        let first: Data
        let second: Data

        init(first: Data, second: Data) {
            self.first = first
            self.second = second
        }

        var fetches: Int { lock.withLock { fetchCount } }

        func fetch(_ listing: AuthorityListing) async throws -> SignedManifest {
            let bytes = lock.withLock { () -> Data in
                fetchCount += 1
                return fetchCount == 1 ? first : second
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return SignedManifest(
                manifest: try decoder.decode(AuthorityManifest.self, from: bytes),
                rawBytes: bytes
            )
        }
    }

    // MARK: - The reviewed manifest is the signed one

    /// The consent surface promises the mandate binds the exact terms
    /// shown. If `consent` refetched, an authority could swap them in
    /// the window between review and agreement.
    func testConsentPinsTheReviewedManifestNotARefetchedOne() async throws {
        let componentId = "onym:component:a"
        let reviewedBytes = manifestBytes(componentId: componentId)
        let swappedBytes = manifestBytes(componentId: componentId, tweak: "-swapped")
        XCTAssertNotEqual(reviewedBytes, swappedBytes)

        let fetcher = SwitchingManifestFetcher(first: reviewedBytes, second: swappedBytes)
        let repository = ModerationRepository(
            authoritiesFetcher: FakeAuthoritiesFetcher(listings: [listing(componentId, name: "A")]),
            manifestFetcher: fetcher,
            mandateStore: InMemoryMandateStore(),
            backend: RecordingBackend(),
            attestation: FakeAttestation(supported: true),
            signer: FakeSigner(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let reviewed = try await repository.manifestForReview(listing(componentId, name: "A"))
        let record = try await repository.consent(
            to: listing(componentId, name: "A"),
            reviewedManifest: reviewed
        )

        XCTAssertEqual(record.mandate.manifestHash, SignedManifest.hash(of: reviewedBytes))
        XCTAssertEqual(record.manifestBytes, reviewedBytes)
        XCTAssertNotEqual(record.mandate.manifestHash, SignedManifest.hash(of: swappedBytes))
        // Exactly one fetch: signing must not go back to the network.
        XCTAssertEqual(fetcher.fetches, 1)
    }

    /// A reviewed manifest from a different authority can't be signed
    /// against this listing.
    func testConsentRejectsManifestForADifferentAuthority() async throws {
        let aID = "onym:component:a"
        let bID = "onym:component:b"
        let repository = makeRepository(
            listings: [listing(aID, name: "A"), listing(bID, name: "B")],
            bytesByComponent: [
                aID: manifestBytes(componentId: aID),
                bID: manifestBytes(componentId: bID),
            ],
            backend: RecordingBackend()
        )

        let otherManifest = try await repository.manifestForReview(listing(bID, name: "B"))
        do {
            _ = try await repository.consent(
                to: listing(aID, name: "A"),
                reviewedManifest: otherManifest
            )
            XCTFail("expected a mismatched-authority manifest to be refused")
        } catch {
            // expected
        }
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

        let record = try await repository.reviewAndConsent(to: listing(componentId, name: "A"))

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

        let first = try await repository.reviewAndConsent(to: listing(aID, name: "A"))
        let second = try await repository.reviewAndConsent(to: listing(bID, name: "B"))

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

        let record = try await repository.reviewAndConsent(to: listing(componentId, name: "A"))

        XCTAssertFalse(record.countersigned)
        XCTAssertEqual(record.mandate.signatures.count, 2)
        XCTAssertEqual(record.mandate.signatures.last, StubEnforcementBackendClient.countersignSentinel)
    }

    func testStubEnrollmentBindingIsStableAcrossCalls() async throws {
        let suite = "stub-backend-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = StubEnforcementBackendClient(defaults: defaults)

        let first = try await stub.enrollDevice(
            EnrollmentRequest(deviceToken: nil, userKey: "u", timestamp: now, signature: Data())
        )
        let second = try await stub.enrollDevice(
            EnrollmentRequest(
                deviceToken: Data("t".utf8),
                userKey: "u",
                timestamp: now.addingTimeInterval(60),
                signature: Data()
            )
        )
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

        _ = try await repository.reviewAndConsent(to: listing(componentId, name: "A"))

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
        _ = try await moderation.reviewAndConsent(to: listing(componentId, name: "A"))

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

extension ModerationRepository {
    /// Test convenience for the two-step consent path: review the
    /// manifest, then consent to that exact value — what the UI does.
    /// Tests that care about the review/sign split call the two methods
    /// directly instead.
    @discardableResult
    func reviewAndConsent(to listing: AuthorityListing) async throws -> MandateRecord {
        let reviewed = try await manifestForReview(listing)
        return try await consent(to: listing, reviewedManifest: reviewed)
    }
}
