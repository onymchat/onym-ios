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
