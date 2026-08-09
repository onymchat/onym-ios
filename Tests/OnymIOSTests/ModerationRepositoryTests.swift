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
        private var records: [MandateRecord]

        init(records: [MandateRecord] = []) {
            self.records = records
        }

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
        var countersignCount: Int { lock.withLock { _countersignCount } }
        private var _enrollRequests: [EnrollmentRequest] = []
        private var _gateRequests: [GateCheckRequest] = []
        private var _countersignCount = 0
        private var _countersignDelayNanoseconds: UInt64 = 0
        var gateResult: GateCheckResult = .clear
        /// When set, `countersignMandate` returns this instead of the
        /// stub sentinel — lets a test assert what the client does with
        /// a backend-supplied signature.
        var countersignature: String = StubEnforcementBackendClient.countersignSentinel
        var countersignDelayNanoseconds: UInt64 {
            get { lock.withLock { _countersignDelayNanoseconds } }
            set { lock.withLock { _countersignDelayNanoseconds = newValue } }
        }

        func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
            lock.withLock { _enrollRequests.append(request) }
            return DeviceEnrollment(deviceBinding: "recorded-enrollment")
        }

        func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
            let delay = lock.withLock { () -> UInt64 in
                _countersignCount += 1
                return _countersignDelayNanoseconds
            }
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            return InterfaceCountersignature(signature: lock.withLock { countersignature })
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

    private enum RegistrationFailure: Error {
        case unavailable
    }

    private final class RecordingAuthorityClient: ModerationAuthorityClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _mandates: [ModerationMandate] = []
        private var _shouldFail = false
        private var _returnedReference: String?
        private var _accepted = true
        private var _registrationError: AuthorityClientError?
        private var _rejectedManifestHash: String?
        private var _registrationDelayNanoseconds: UInt64 = 0

        var mandates: [ModerationMandate] { lock.withLock { _mandates } }
        var shouldFail: Bool {
            get { lock.withLock { _shouldFail } }
            set { lock.withLock { _shouldFail = newValue } }
        }
        var returnedReference: String? {
            get { lock.withLock { _returnedReference } }
            set { lock.withLock { _returnedReference = newValue } }
        }
        var accepted: Bool {
            get { lock.withLock { _accepted } }
            set { lock.withLock { _accepted = newValue } }
        }
        var registrationError: AuthorityClientError? {
            get { lock.withLock { _registrationError } }
            set { lock.withLock { _registrationError = newValue } }
        }
        var rejectedManifestHash: String? {
            get { lock.withLock { _rejectedManifestHash } }
            set { lock.withLock { _rejectedManifestHash = newValue } }
        }
        var registrationDelayNanoseconds: UInt64 {
            get { lock.withLock { _registrationDelayNanoseconds } }
            set { lock.withLock { _registrationDelayNanoseconds = newValue } }
        }

        func registerMandate(
            _ mandate: ModerationMandate
        ) async throws -> MandateRegistrationReceipt {
            let state = lock.withLock {
                () -> (Bool, String?, Bool, AuthorityClientError?, String?, UInt64) in
                _mandates.append(mandate)
                return (
                    _shouldFail,
                    _returnedReference,
                    _accepted,
                    _registrationError,
                    _rejectedManifestHash,
                    _registrationDelayNanoseconds
                )
            }
            if state.5 > 0 {
                try await Task.sleep(nanoseconds: state.5)
            }
            if state.0 { throw RegistrationFailure.unavailable }
            if let error = state.3 { throw error }
            if state.4 == mandate.manifestHash {
                throw AuthorityClientError.rejected(
                    AuthorityRejection(
                        statusCode: 400,
                        rawCode: "bad_request",
                        message: "manifest rotated"
                    )
                )
            }
            let mandateRef: String
            if let returnedReference = state.1 {
                mandateRef = returnedReference
            } else {
                mandateRef = try mandate.mandateHash()
            }
            return MandateRegistrationReceipt(
                mandateRef: mandateRef,
                accepted: state.2
            )
        }

        func fileReport(_ report: Report) async throws -> ReportReceipt {
            throw ModerationError.notImplemented("unused")
        }
        func respond(_ response: CaseResponse) async throws {
            throw ModerationError.notImplemented("unused")
        }
        func appeal(_ submission: AppealSubmission) async throws {
            throw ModerationError.notImplemented("unused")
        }
        func queryStatus(caseId: String) async throws -> CaseStatus {
            throw ModerationError.notImplemented("unused")
        }
    }

    private struct RecordingAuthorityClientFactory: ModerationAuthorityClientFactory {
        let authority: RecordingAuthorityClient

        func client(for listing: AuthorityListing) -> any ModerationAuthorityClient {
            authority
        }
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
            apiBaseURL: URL(string: "https://api.example.com/\(name)")!,
            operatorPublicKeyBase64: ""
        )
    }

    private func makeRepository(
        listings: [AuthorityListing],
        bytesByComponent: [String: Data],
        backend: any EnforcementBackendClient,
        authorityClient: RecordingAuthorityClient? = nil,
        attestation: any DeviceAttestationProvider = FakeAttestation(supported: true),
        store: MandateStore? = nil
    ) -> ModerationRepository {
        let authorityClients: any ModerationAuthorityClientFactory
        if let authorityClient {
            authorityClients = RecordingAuthorityClientFactory(authority: authorityClient)
        } else {
            authorityClients = StubModerationAuthorityClientFactory()
        }
        return ModerationRepository(
            authoritiesFetcher: FakeAuthoritiesFetcher(listings: listings),
            manifestFetcher: FakeManifestFetcher(bytesByComponent: bytesByComponent),
            mandateStore: store ?? InMemoryMandateStore(),
            backend: backend,
            authorityClients: authorityClients,
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
            authorityClients: StubModerationAuthorityClientFactory(),
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

    // MARK: - Authority registration

    func testCountersignedMandateActivatesOnlyAfterAuthorityRegistration() async throws {
        let componentId = "onym:component:a"
        let backend = RecordingBackend()
        backend.countersignature = "interface-signature"
        let authority = RecordingAuthorityClient()
        let repository = makeRepository(
            listings: [listing(componentId, name: "A")],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            authorityClient: authority
        )

        let record = try await repository.reviewAndConsent(to: listing(componentId, name: "A"))

        XCTAssertTrue(record.countersigned)
        XCTAssertTrue(record.authorityRegistered)
        XCTAssertTrue(record.isActive)
        XCTAssertEqual(authority.mandates, [record.mandate])
        XCTAssertEqual(backend.countersignCount, 1)
    }

    func testFailedRegistrationPersistsAndRetriesTheExactMandate() async throws {
        let componentId = "onym:component:a"
        let selected = listing(componentId, name: "A")
        let backend = RecordingBackend()
        backend.countersignature = "interface-signature"
        let authority = RecordingAuthorityClient()
        authority.shouldFail = true
        let store = InMemoryMandateStore()
        let repository = makeRepository(
            listings: [selected],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            authorityClient: authority,
            store: store
        )
        let reviewed = try await repository.manifestForReview(selected)

        do {
            _ = try await repository.consent(to: selected, reviewedManifest: reviewed)
            XCTFail("expected registration failure")
        } catch RegistrationFailure.unavailable {
            // expected
        }

        let pending = try XCTUnwrap(store.load().first)
        XCTAssertTrue(pending.countersigned)
        XCTAssertFalse(pending.authorityRegistered)
        XCTAssertTrue(pending.registrationPending)
        XCTAssertFalse(pending.isActive)
        let activeAfterFailure = await repository.activeMandateRecord()
        XCTAssertNil(activeAfterFailure)

        authority.shouldFail = false
        let activated = try await repository.consent(to: selected, reviewedManifest: reviewed)

        XCTAssertTrue(activated.authorityRegistered)
        XCTAssertTrue(activated.isActive)
        XCTAssertEqual(authority.mandates, [pending.mandate, pending.mandate])
        XCTAssertEqual(backend.enrollRequests.count, 1, "retry must not mint a new mandate")
        XCTAssertEqual(backend.countersignCount, 1, "retry must reuse the countersignature")
        XCTAssertEqual(store.load().count, 1)
    }

    func testStartRetriesNewestPersistedRegistration() async throws {
        let componentId = "onym:component:a"
        let selected = listing(componentId, name: "A")
        let bytes = manifestBytes(componentId: componentId)
        let pending = MandateRecord(
            mandate: ModerationMandate(
                user: "onym:key:test-user",
                interface: ModerationRepository.interfaceComponentId,
                authority: componentId,
                manifestHash: SignedManifest.hash(of: bytes),
                classes: ["csam"],
                deviceBinding: "device-1",
                acceptedAt: now,
                signatures: ["user-signature", "interface-signature"]
            ),
            manifestBytes: bytes,
            authorityName: "A",
            countersigned: true,
            isActive: false,
            createdAt: now
        )
        let store = InMemoryMandateStore(records: [pending])
        let authority = RecordingAuthorityClient()
        let repository = makeRepository(
            listings: [selected],
            bytesByComponent: [componentId: bytes],
            backend: RecordingBackend(),
            authorityClient: authority,
            store: store
        )

        await repository.start()
        for _ in 0..<100 {
            if await repository.activeMandateRecord() != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let activeRecord = await repository.activeMandateRecord()
        let active = try XCTUnwrap(activeRecord)
        XCTAssertTrue(active.authorityRegistered)
        XCTAssertEqual(active.mandate, pending.mandate)
        XCTAssertEqual(authority.mandates, [pending.mandate])
    }

    func testStartRetryDoesNotReplaceANewerActiveAuthority() async throws {
        let oldID = "onym:component:old"
        let currentID = "onym:component:current"
        let oldBytes = manifestBytes(componentId: oldID)
        let currentBytes = manifestBytes(componentId: currentID)
        let pending = MandateRecord(
            mandate: ModerationMandate(
                user: "onym:key:test-user",
                interface: ModerationRepository.interfaceComponentId,
                authority: oldID,
                manifestHash: SignedManifest.hash(of: oldBytes),
                classes: ["csam"],
                deviceBinding: "device-1",
                acceptedAt: now,
                signatures: ["user-signature", "interface-signature"]
            ),
            manifestBytes: oldBytes,
            authorityName: "Old",
            countersigned: true,
            isActive: false,
            createdAt: now
        )
        let current = MandateRecord(
            mandate: ModerationMandate(
                user: "onym:key:test-user",
                interface: ModerationRepository.interfaceComponentId,
                authority: currentID,
                manifestHash: SignedManifest.hash(of: currentBytes),
                classes: ["csam"],
                deviceBinding: "device-1",
                acceptedAt: now.addingTimeInterval(1),
                signatures: ["user-signature", "interface-signature"]
            ),
            manifestBytes: currentBytes,
            authorityName: "Current",
            countersigned: true,
            authorityRegistered: true,
            isActive: true,
            createdAt: now.addingTimeInterval(1)
        )
        let store = InMemoryMandateStore(records: [current, pending])
        let authority = RecordingAuthorityClient()
        let repository = makeRepository(
            listings: [listing(oldID, name: "Old"), listing(currentID, name: "Current")],
            bytesByComponent: [oldID: oldBytes, currentID: currentBytes],
            backend: RecordingBackend(),
            authorityClient: authority,
            store: store
        )

        await repository.start()
        for _ in 0..<100 {
            if store.load().first(where: { $0.mandate.authority == oldID })?.authorityRegistered
                == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let records = store.load()
        let resolvedOld = try XCTUnwrap(records.first(where: { $0.mandate.authority == oldID }))
        XCTAssertTrue(resolvedOld.authorityRegistered)
        XCTAssertFalse(resolvedOld.isActive)
        XCTAssertEqual(records.first(where: \.isActive)?.mandate.authority, currentID)
        XCTAssertEqual(authority.mandates, [pending.mandate])
    }

    func testStartRetryAndExplicitConsentShareOneRegistrationFlight() async throws {
        let componentId = "onym:component:a"
        let selected = listing(componentId, name: "A")
        let bytes = manifestBytes(componentId: componentId)
        let pending = MandateRecord(
            mandate: ModerationMandate(
                user: "onym:key:test-user",
                interface: ModerationRepository.interfaceComponentId,
                authority: componentId,
                manifestHash: SignedManifest.hash(of: bytes),
                classes: ["csam"],
                deviceBinding: "device-1",
                acceptedAt: now,
                signatures: ["user-signature", "interface-signature"]
            ),
            manifestBytes: bytes,
            authorityName: "A",
            countersigned: true,
            isActive: false,
            createdAt: now
        )
        let store = InMemoryMandateStore(records: [pending])
        let authority = RecordingAuthorityClient()
        authority.registrationDelayNanoseconds = 100_000_000
        let repository = makeRepository(
            listings: [selected],
            bytesByComponent: [componentId: bytes],
            backend: RecordingBackend(),
            authorityClient: authority,
            store: store
        )

        await repository.start()
        for _ in 0..<100 {
            if authority.mandates.count == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let reviewed = try await repository.manifestForReview(selected)
        let activated = try await repository.consent(
            to: selected,
            reviewedManifest: reviewed
        )

        XCTAssertTrue(activated.authorityRegistered)
        XCTAssertTrue(activated.isActive)
        XCTAssertEqual(authority.mandates, [pending.mandate])
        XCTAssertEqual(store.load().count, 1)
    }

    func testMismatchedAuthorityReferenceDoesNotActivateMandate() async throws {
        let componentId = "onym:component:a"
        let backend = RecordingBackend()
        backend.countersignature = "interface-signature"
        let authority = RecordingAuthorityClient()
        authority.returnedReference = "wrong-reference"
        authority.accepted = false
        let store = InMemoryMandateStore()
        let repository = makeRepository(
            listings: [listing(componentId, name: "A")],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            authorityClient: authority,
            store: store
        )

        do {
            _ = try await repository.reviewAndConsent(to: listing(componentId, name: "A"))
            XCTFail("expected reference mismatch")
        } catch let AuthorityClientError.mandateReferenceMismatch(expected, received) {
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(received, "wrong-reference")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(store.load().isEmpty)
        let activeAfterMismatch = await repository.activeMandateRecord()
        XCTAssertNil(activeAfterMismatch)
    }

    func testAuthorityRejectionDoesNotMasqueradeAsReferenceMismatch() async throws {
        let componentId = "onym:component:a"
        let backend = RecordingBackend()
        backend.countersignature = "interface-signature"
        let authority = RecordingAuthorityClient()
        authority.accepted = false
        let store = InMemoryMandateStore()
        let repository = makeRepository(
            listings: [listing(componentId, name: "A")],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            authorityClient: authority,
            store: store
        )

        do {
            _ = try await repository.reviewAndConsent(to: listing(componentId, name: "A"))
            XCTFail("expected Authority rejection")
        } catch let AuthorityClientError.mandateNotAccepted(mandateRef) {
            XCTAssertEqual(mandateRef, try XCTUnwrap(authority.mandates.first).mandateHash())
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(store.load().isEmpty)

        authority.accepted = true
        let retried = try await repository.reviewAndConsent(to: listing(componentId, name: "A"))
        XCTAssertTrue(retried.isActive)
        XCTAssertTrue(retried.authorityRegistered)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(backend.countersignCount, 2, "a terminal refusal mints a fresh artifact")
    }

    func testOrdinary4xxIsTerminalButRateLimitRetainsExactRetry() async throws {
        let componentId = "onym:component:a"
        let selected = listing(componentId, name: "A")
        let backend = RecordingBackend()
        backend.countersignature = "interface-signature"
        let authority = RecordingAuthorityClient()
        let store = InMemoryMandateStore()
        let repository = makeRepository(
            listings: [selected],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            authorityClient: authority,
            store: store
        )
        let reviewed = try await repository.manifestForReview(selected)

        authority.registrationError = .rejected(
            AuthorityRejection(statusCode: 404, rawCode: "not_found", message: "not found")
        )
        do {
            _ = try await repository.consent(to: selected, reviewedManifest: reviewed)
            XCTFail("expected terminal 404")
        } catch AuthorityClientError.rejected {
            // expected
        }
        XCTAssertTrue(store.load().isEmpty)

        authority.registrationError = .rejected(
            AuthorityRejection(statusCode: 429, rawCode: "rate_limited", message: "slow down")
        )
        do {
            _ = try await repository.consent(to: selected, reviewedManifest: reviewed)
            XCTFail("expected retryable 429")
        } catch AuthorityClientError.rejected {
            // expected
        }
        let pending = try XCTUnwrap(store.load().first)
        XCTAssertTrue(pending.registrationPending)

        authority.registrationError = nil
        let activated = try await repository.consent(to: selected, reviewedManifest: reviewed)
        XCTAssertTrue(activated.isActive)
        XCTAssertEqual(Array(authority.mandates.suffix(2)), [pending.mandate, pending.mandate])
    }

    func testManifestRotationResolvesOldPendingBeforeRegisteringNewConsent() async throws {
        let componentId = "onym:component:a"
        let selected = listing(componentId, name: "A")
        let oldBytes = manifestBytes(componentId: componentId)
        let newBytes = manifestBytes(componentId: componentId, tweak: "-rotated")
        let fetcher = SwitchingManifestFetcher(first: oldBytes, second: newBytes)
        let backend = RecordingBackend()
        backend.countersignature = "interface-signature"
        let authority = RecordingAuthorityClient()
        authority.shouldFail = true
        let store = InMemoryMandateStore()
        let repository = ModerationRepository(
            authoritiesFetcher: FakeAuthoritiesFetcher(listings: [selected]),
            manifestFetcher: fetcher,
            mandateStore: store,
            backend: backend,
            authorityClients: RecordingAuthorityClientFactory(authority: authority),
            attestation: FakeAttestation(supported: true),
            signer: FakeSigner(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let oldReview = try await repository.manifestForReview(selected)
        do {
            _ = try await repository.consent(to: selected, reviewedManifest: oldReview)
            XCTFail("expected ambiguous first registration")
        } catch RegistrationFailure.unavailable {
            // expected
        }
        let oldPending = try XCTUnwrap(store.load().first)
        XCTAssertTrue(oldPending.registrationPending)

        authority.shouldFail = false
        authority.rejectedManifestHash = oldPending.mandate.manifestHash
        let newReview = try await repository.manifestForReview(selected)
        let current = try await repository.consent(to: selected, reviewedManifest: newReview)

        XCTAssertEqual(current.mandate.manifestHash, SignedManifest.hash(of: newBytes))
        XCTAssertTrue(current.authorityRegistered)
        XCTAssertTrue(current.isActive)
        XCTAssertEqual(store.load(), [current], "rotated pending attempt must not remain orphaned")
        XCTAssertEqual(backend.countersignCount, 2)
        XCTAssertEqual(authority.mandates.map(\.manifestHash), [
            oldPending.mandate.manifestHash,
            oldPending.mandate.manifestHash,
            current.mandate.manifestHash,
        ])
    }

    func testOverlappingConsentCallsShareOneArtifact() async throws {
        let componentId = "onym:component:a"
        let selected = listing(componentId, name: "A")
        let backend = RecordingBackend()
        backend.countersignature = "interface-signature"
        backend.countersignDelayNanoseconds = 50_000_000
        let authority = RecordingAuthorityClient()
        let store = InMemoryMandateStore()
        let repository = makeRepository(
            listings: [selected],
            bytesByComponent: [componentId: manifestBytes(componentId: componentId)],
            backend: backend,
            authorityClient: authority,
            store: store
        )
        let reviewed = try await repository.manifestForReview(selected)

        async let first = repository.consent(to: selected, reviewedManifest: reviewed)
        async let second = repository.consent(to: selected, reviewedManifest: reviewed)
        let (firstRecord, secondRecord) = try await (first, second)

        XCTAssertEqual(firstRecord, secondRecord)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(backend.enrollRequests.count, 1)
        XCTAssertEqual(backend.countersignCount, 1)
        XCTAssertEqual(authority.mandates.count, 1)
    }

    func testRegistrationActivatesOnlyOneOfTwoRecordsSharingAContentHash() async throws {
        let componentId = "onym:component:a"
        let selected = listing(componentId, name: "A")
        let bytes = manifestBytes(componentId: componentId)
        let mandate = ModerationMandate(
            user: "onym:key:test-user",
            interface: ModerationRepository.interfaceComponentId,
            authority: componentId,
            manifestHash: SignedManifest.hash(of: bytes),
            classes: ["csam"],
            deviceBinding: "same-binding",
            acceptedAt: now,
            signatures: ["user-signature", "interface-signature-a"]
        )
        var otherMandate = mandate
        otherMandate.signatures = ["user-signature", "interface-signature-b"]
        XCTAssertEqual(try mandate.mandateHash(), try otherMandate.mandateHash())

        let first = MandateRecord(
            mandate: mandate,
            manifestBytes: bytes,
            authorityName: "A",
            countersigned: true,
            isActive: false,
            createdAt: now
        )
        let second = MandateRecord(
            mandate: otherMandate,
            manifestBytes: bytes,
            authorityName: "A",
            countersigned: true,
            isActive: false,
            createdAt: now
        )
        let store = InMemoryMandateStore(records: [first, second])
        let authority = RecordingAuthorityClient()
        let repository = makeRepository(
            listings: [selected],
            bytesByComponent: [componentId: bytes],
            backend: RecordingBackend(),
            authorityClient: authority,
            store: store
        )
        let reviewed = try await repository.manifestForReview(selected)

        _ = try await repository.consent(to: selected, reviewedManifest: reviewed)

        let records = store.load()
        XCTAssertEqual(records.filter(\.isActive).count, 1)
        XCTAssertEqual(records.filter(\.authorityRegistered).count, 1)
        XCTAssertEqual(records.first?.mandate.signatures.last, "interface-signature-a")
        XCTAssertTrue(try XCTUnwrap(records.first).isActive)
        XCTAssertFalse(try XCTUnwrap(records.last).isActive)
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

    func testLegacyMandateRecordDecodesAsUnregistered() throws {
        let record = MandateRecord(
            mandate: ModerationMandate(
                user: "onym:key:test-user",
                interface: ModerationRepository.interfaceComponentId,
                authority: "onym:component:a",
                manifestHash: String(repeating: "a", count: 64),
                classes: ["csam"],
                deviceBinding: "device-1",
                acceptedAt: now,
                signatures: ["user", StubEnforcementBackendClient.countersignSentinel]
            ),
            manifestBytes: Data("manifest".utf8),
            authorityName: "A",
            countersigned: false,
            isActive: true,
            createdAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
        )
        json.removeValue(forKey: "authorityRegistered")
        let legacyBytes = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(MandateRecord.self, from: legacyBytes)

        XCTAssertFalse(decoded.authorityRegistered)
        XCTAssertEqual(decoded.mandate, record.mandate)
        XCTAssertTrue(decoded.isActive)
    }

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
