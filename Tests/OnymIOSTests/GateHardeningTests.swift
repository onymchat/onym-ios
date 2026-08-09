import XCTest
@testable import OnymModeration

/// The enforcement-path hardening: signed session payloads a backend
/// can actually verify, a countersignature round-trip that can't alter
/// consent, stale gate completions that can't reopen the app, and a
/// grace window that can't be extended by winding the clock back.
final class GateHardeningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Signed session payloads

    /// The backend receives token, userKey and timestamp, so it must be
    /// able to recompute exactly what was signed from those fields.
    func testEnrollmentPayloadIsReconstructibleFromTransmittedFields() {
        let token = Data("device-token".utf8)
        let request = EnrollmentRequest(
            deviceToken: token,
            userKey: "onym:key:user",
            timestamp: now,
            signature: Data()
        )
        let recomputed = EnrollmentRequest.signedPayload(
            deviceToken: request.deviceToken,
            userKey: request.userKey,
            timestamp: request.timestamp
        )
        XCTAssertEqual(
            recomputed,
            EnrollmentRequest.signedPayload(deviceToken: token, userKey: "onym:key:user", timestamp: now)
        )
    }

    func testEnrollmentAndGatePayloadsAreDomainSeparated() {
        let token = Data("t".utf8)
        let enrollment = EnrollmentRequest.signedPayload(
            deviceToken: token, userKey: "u", timestamp: now
        )
        let gate = GateCheckRequest.signedPayload(
            deviceToken: token, userKey: "u", mandateRef: nil, timestamp: now
        )
        // Otherwise an enrollment signature could be replayed as a
        // gate-check signature for the same session.
        XCTAssertNotEqual(enrollment, gate)
    }

    /// Length-prefixing makes concatenation injective: no two distinct
    /// field splits can produce identical bytes.
    func testFieldBoundariesAreUnambiguous() {
        let a = EnrollmentRequest.signedPayload(
            deviceToken: Data("ab".utf8), userKey: "c", timestamp: now
        )
        let b = EnrollmentRequest.signedPayload(
            deviceToken: Data("a".utf8), userKey: "bc", timestamp: now
        )
        XCTAssertNotEqual(a, b)
    }

    func testGatePayloadCoversMandateRef() {
        let one = GateCheckRequest.signedPayload(
            deviceToken: nil, userKey: "u", mandateRef: "mandate-a", timestamp: now
        )
        let two = GateCheckRequest.signedPayload(
            deviceToken: nil, userKey: "u", mandateRef: "mandate-b", timestamp: now
        )
        XCTAssertNotEqual(one, two)
    }

    func testPayloadChangesWithTimestamp() {
        let one = EnrollmentRequest.signedPayload(deviceToken: nil, userKey: "u", timestamp: now)
        let two = EnrollmentRequest.signedPayload(
            deviceToken: nil, userKey: "u", timestamp: now.addingTimeInterval(60)
        )
        XCTAssertNotEqual(one, two)
    }

    // MARK: - Countersignature can't alter consent

    /// `countersignMandate` returns only a signature, so there is no
    /// channel through which a backend could change a consented field.
    /// This is a type-level guarantee; the test pins it against drift.
    func testCountersignatureCarriesOnlyASignature() async throws {
        let suite = "countersign-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let mandate = ModerationMandate(
            user: "onym:key:user",
            interface: "onym:component:onym-ios",
            authority: "onym:component:authority",
            manifestHash: "aa",
            classes: ["csam"],
            deviceBinding: "enrollment-1",
            acceptedAt: now,
            signatures: ["user-sig"]
        )
        let countersignature = try await StubEnforcementBackendClient(defaults: defaults)
            .countersignMandate(mandate)

        XCTAssertEqual(countersignature.signature, StubEnforcementBackendClient.countersignSentinel)
        // The mandate the client holds is untouched by the round-trip.
        XCTAssertEqual(mandate.signatures, ["user-sig"])
    }

    // MARK: - Clock rollback

    func testClockBehindLastSuccessBlocks() {
        let persisted = PersistedGateState(
            lastResult: .clear,
            lastSuccessAt: now.addingTimeInterval(60)  // "future" relative to now
        )
        let (status, kept) = GateCheckRepository.derive(
            persisted: persisted,
            attempt: .unreachable,
            now: now,
            policy: .default
        )
        XCTAssertEqual(status, .gateCheckRequired(.clockRollback))
        XCTAssertEqual(kept, persisted)
    }

    /// The rollback that used to buy unlimited grace: set the clock far
    /// back, block the backend, keep serving a cached `.clear`.
    func testLargeRollbackDoesNotExtendGrace() {
        let persisted = PersistedGateState(
            lastResult: .clear,
            lastSuccessAt: now.addingTimeInterval(365 * 86_400)
        )
        let (status, _) = GateCheckRepository.derive(
            persisted: persisted,
            attempt: .unreachable,
            now: now,
            policy: .default
        )
        XCTAssertEqual(status, .gateCheckRequired(.clockRollback))
    }

    func testZeroAgeStillInsideGrace() {
        let persisted = PersistedGateState(lastResult: .clear, lastSuccessAt: now)
        let (status, _) = GateCheckRepository.derive(
            persisted: persisted,
            attempt: .unreachable,
            now: now,
            policy: .default
        )
        XCTAssertEqual(status, .operational(openCases: []))
    }

    // MARK: - Stale completions can't reopen the app

    /// A backend whose responses complete out of order: the first call
    /// is slow and answers `.clear`, the second is fast and answers
    /// `.banned`. The slow completion must not overwrite the ban.
    private final class ReorderingBackend: EnforcementBackendClient, @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        /// Signalled once the fast (second) call has finished.
        let fastCallFinished = XCTestExpectation(description: "fast call finished")

        func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
            DeviceEnrollment(deviceBinding: "enrollment-1")
        }

        func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
            InterfaceCountersignature(signature: "sig")
        }

        func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult {
            let index = lock.withLock { () -> Int in
                callCount += 1
                return callCount
            }
            if index == 1 {
                // Slow: finishes after the ban has landed.
                try? await Task.sleep(nanoseconds: 250_000_000)
                return .clear
            }
            let banned = GateCheckResult.banned(
                BanState(verdictRef: "verdict-1", authorityContact: "appeals@authority.example")
            )
            fastCallFinished.fulfill()
            return banned
        }
    }

    /// Throws a fixed error from every gate check.
    private struct ThrowingBackend: EnforcementBackendClient {
        let error: Error
        func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
            DeviceEnrollment(deviceBinding: "enrollment-1")
        }
        func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
            InterfaceCountersignature(signature: "unused")
        }
        func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult {
            throw error
        }
    }

    private func gateStatus(afterBackendError error: Error) async -> GateStatus {
        let backend = ThrowingBackend(error: error)
        let moderation = ModerationRepository(
            authoritiesFetcher: EmptyAuthoritiesFetcher(),
            manifestFetcher: UnusedManifestFetcher(),
            mandateStore: SeededMandateStore(records: [seededActiveRecord()]),
            backend: backend,
            authorityClients: StubModerationAuthorityClientFactory(),
            attestation: FixedAttestation(),
            signer: FixedSigner(),
            clock: { [now] in now }
        )
        let gate = GateCheckRepository(
            attestation: FixedAttestation(),
            backend: backend,
            moderation: moderation,
            signer: FixedSigner(),
            store: InMemoryGateStateStore(),
            clock: { [now] in now }
        )
        await gate.checkNow()
        return await gate.currentStatus()
    }

    func testReplayedSignature401BlocksAsBackendRefused() async {
        let status = await gateStatus(afterBackendError: AuthorityClientError.rejected(
            AuthorityRejection(statusCode: 401, rawCode: "signature_invalid", message: "replayed")
        ))
        XCTAssertEqual(status, .gateCheckRequired(.backendRefused))
    }

    func testNoMandateRoutesToEnrollmentLost() async {
        // `no_mandate` is not user-transient — the gate flow maps
        // `.enrollmentLost` to re-consent, which re-runs enrollment.
        let status = await gateStatus(afterBackendError: AuthorityClientError.rejected(
            AuthorityRejection(statusCode: 400, rawCode: "no_mandate", message: "gone")
        ))
        XCTAssertEqual(status, .gateCheckRequired(.enrollmentLost))
    }

    func testDeployRegression404FallsThroughToGrace() async {
        // A renamed route / body drift is NOT a session refusal: with
        // no history it degrades through the unreachable rules, never
        // to backendRefused.
        let status = await gateStatus(afterBackendError: AuthorityClientError.rejected(
            AuthorityRejection(statusCode: 404, rawCode: "http_404", message: "no route")
        ))
        XCTAssertEqual(status, .gateCheckRequired(.neverChecked))
    }

    func testServerError500FallsThroughToGrace() async {
        let status = await gateStatus(afterBackendError: AuthorityClientError.rejected(
            AuthorityRejection(statusCode: 500, rawCode: "internal_error", message: "boom")
        ))
        XCTAssertEqual(status, .gateCheckRequired(.neverChecked))
    }

    /// Answers every gate check with a fixed result.
    private struct FixedResultBackend: EnforcementBackendClient {
        let result: GateCheckResult
        func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
            DeviceEnrollment(deviceBinding: "enrollment-1")
        }
        func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
            InterfaceCountersignature(signature: "unused")
        }
        func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult {
            result
        }
    }

    private func seededActiveRecord() -> MandateRecord {
        MandateRecord(
            mandate: ModerationMandate(
                user: "onym:key:user",
                interface: "onym:component:onym-ios",
                authority: "onym:component:authority",
                manifestHash: "aa",
                classes: ["csam"],
                deviceBinding: "enrollment-1",
                acceptedAt: now,
                signatures: ["user-sig"]
            ),
            manifestBytes: Data("{}".utf8),
            authorityName: "A",
            countersigned: false,
            isActive: true,
            createdAt: now
        )
    }

    private func bannedResultWithVerdict(mandateRef: String) -> GateCheckResult {
        .banned(BanState(
            verdictRef: "verdict-1",
            verdict: Verdict(
                caseId: "case-1",
                authority: "onym:component:authority",
                mandateRef: mandateRef,
                accusedKeys: ["onym:key:user"],
                deviceBinding: "enrollment-1",
                classId: "csam",
                disposition: .ban,
                marks: Marks(caseOpen: false, banned: true),
                banExpires: nil,
                executeAfter: now,
                reasoning: "reasoning",
                appealDeadline: now,
                decidedAt: now,
                signature: "not-a-real-signature",
                isFinal: false
            ),
            authorityContact: "appeals@authority.example"
        ))
    }

    func testUnverifiableBanVerdictIsStrippedButBanStands() async throws {
        // The served verdict names a mandateRef no local record holds —
        // validation cannot even locate the consented terms. The ban
        // must stand (the marks are the enforcement) with the verdict
        // narrative stripped, never render unauthenticated content.
        let backend = FixedResultBackend(
            result: bannedResultWithVerdict(mandateRef: "unknown-ref")
        )
        let moderation = ModerationRepository(
            authoritiesFetcher: EmptyAuthoritiesFetcher(),
            manifestFetcher: UnusedManifestFetcher(),
            mandateStore: SeededMandateStore(records: [seededActiveRecord()]),
            backend: backend,
            authorityClients: StubModerationAuthorityClientFactory(),
            attestation: FixedAttestation(),
            signer: FixedSigner(),
            clock: { [now] in now }
        )
        let gate = GateCheckRepository(
            attestation: FixedAttestation(),
            backend: backend,
            moderation: moderation,
            signer: FixedSigner(),
            store: InMemoryGateStateStore(),
            clock: { [now] in now }
        )

        await gate.checkNow()

        guard case .banned(let state) = await gate.currentStatus() else {
            return XCTFail("the ban must stand")
        }
        XCTAssertNil(state.verdict, "an unverifiable verdict must not render")
        XCTAssertEqual(state.verdictRef, "verdict-1")
    }

    func testStagePropVerdictSurvivesWhenValidationDisabled() async throws {
        // The UI-test composition disables validation because scenario
        // fixtures are stage props; the ban screen must keep its rows.
        let backend = FixedResultBackend(
            result: bannedResultWithVerdict(mandateRef: "unknown-ref")
        )
        let moderation = ModerationRepository(
            authoritiesFetcher: EmptyAuthoritiesFetcher(),
            manifestFetcher: UnusedManifestFetcher(),
            mandateStore: SeededMandateStore(records: [seededActiveRecord()]),
            backend: backend,
            authorityClients: StubModerationAuthorityClientFactory(),
            attestation: FixedAttestation(),
            signer: FixedSigner(),
            clock: { [now] in now }
        )
        let gate = GateCheckRepository(
            attestation: FixedAttestation(),
            backend: backend,
            moderation: moderation,
            signer: FixedSigner(),
            store: InMemoryGateStateStore(),
            validatesBanVerdicts: false,
            clock: { [now] in now }
        )

        await gate.checkNow()

        guard case .banned(let state) = await gate.currentStatus() else {
            return XCTFail("the ban must stand")
        }
        XCTAssertNotNil(state.verdict)
    }

    private struct FixedAttestation: DeviceAttestationProvider {
        var isSupported: Bool { true }
        func generateToken() async throws -> Data { Data("token".utf8) }
    }

    private struct FixedSigner: ModerationSigner {
        func userKeyID() async throws -> String { "onym:key:user" }
        func sign(_ message: Data) async throws -> Data { Data("sig".utf8) }
    }

    private final class InMemoryGateStateStore: GateStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: PersistedGateState?
        func load() -> PersistedGateState? { lock.withLock { state } }
        func save(_ state: PersistedGateState?) { lock.withLock { self.state = state } }
    }

    private final class SeededMandateStore: MandateStore, @unchecked Sendable {
        private let records: [MandateRecord]
        init(records: [MandateRecord]) { self.records = records }
        func load() -> [MandateRecord] { records }
        func save(_ records: [MandateRecord]) {}
    }

    private struct EmptyAuthoritiesFetcher: KnownAuthoritiesFetcher {
        func fetchLatest() async throws -> [AuthorityListing] { [] }
    }

    private struct UnusedManifestFetcher: AuthorityManifestFetcher {
        func fetch(_ listing: AuthorityListing) async throws -> SignedManifest {
            throw ModerationError.notImplemented("unused")
        }
    }

    func testStaleGateCompletionDoesNotOverwriteNewerBan() async throws {
        let mandate = ModerationMandate(
            user: "onym:key:user",
            interface: "onym:component:onym-ios",
            authority: "onym:component:authority",
            manifestHash: "aa",
            classes: ["csam"],
            deviceBinding: "enrollment-1",
            acceptedAt: now,
            signatures: ["user-sig"]
        )
        let record = MandateRecord(
            mandate: mandate,
            manifestBytes: Data("{}".utf8),
            authorityName: "A",
            countersigned: false,
            isActive: true,
            createdAt: now
        )
        let backend = ReorderingBackend()
        let moderation = ModerationRepository(
            authoritiesFetcher: EmptyAuthoritiesFetcher(),
            manifestFetcher: UnusedManifestFetcher(),
            mandateStore: SeededMandateStore(records: [record]),
            backend: backend,
            authorityClients: StubModerationAuthorityClientFactory(),
            attestation: FixedAttestation(),
            signer: FixedSigner(),
            clock: { [now] in now }
        )
        let gate = GateCheckRepository(
            attestation: FixedAttestation(),
            backend: backend,
            moderation: moderation,
            signer: FixedSigner(),
            store: InMemoryGateStateStore(),
            clock: { [now] in now }
        )

        // Start the slow check, then the fast one; await both.
        async let slow: Void = gate.checkNow()
        try await Task.sleep(nanoseconds: 20_000_000)
        async let fast: Void = gate.checkNow()
        _ = await (slow, fast)

        await fulfillment(of: [backend.fastCallFinished], timeout: 5)

        // The slow `.clear` resumed last; without the generation guard
        // it would have replaced the ban and reopened the app.
        let status = await gate.currentStatus()
        XCTAssertEqual(
            status,
            .banned(BanState(verdictRef: "verdict-1", authorityContact: "appeals@authority.example"))
        )
    }
}
