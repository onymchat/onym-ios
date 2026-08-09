import CryptoKit
import XCTest
@testable import OnymIOS
import OnymModeration
import OnymModerationUI

/// Device recovery: the grant object, its wire crossings, the gate
/// repository's redemption, and the claim flow's state machine. The
/// invariant under test everywhere: nothing in this path unbans a
/// device on the client's own say-so — the moderator's signed grant is
/// the only object that moves anything, and the client treats it as
/// opaque signed bytes.
final class DeviceRecoveryTests: XCTestCase {
    private var session: URLSession!
    private let baseURL = URL(string: "https://moderation.test")!

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - The grant object

    /// Grantee matches `CapturingSigner.userKeyID()` — the repository
    /// refuses to present a grant issued to any other key.
    private static let grantJSON = #"{"grantVersion":1,"caseId":"case-1","grantee":"onym:key:test","authority":"onym:component:authority","issuedAt":"2026-08-09T00:00:00Z","signature":"c2ln"}"#
    private static let unbanGrantJSON = #"{"grantType":"onym-unban-grant-v1","grantVersion":1,"claimId":"claim-1","grantee":"onym:key:test","authority":"onym:component:authority","issuedAt":"2026-08-09T00:00:00Z","signature":"c2ln"}"#

    func testGrantParsesAndKeepsTheExactBytes() throws {
        let raw = Data(Self.grantJSON.utf8)
        let grant = try RecoveryGrant(raw: raw)
        XCTAssertEqual(grant.version, 1)
        XCTAssertEqual(grant.caseId, "case-1")
        XCTAssertEqual(grant.grantee, "onym:key:test")
        XCTAssertEqual(grant.authority, "onym:component:authority")
        XCTAssertEqual(grant.raw, raw, "the signed bytes travel verbatim")
    }

    func testCaseFreeUnbanGrantParsesWithoutACaseId() throws {
        let raw = Data(Self.unbanGrantJSON.utf8)
        let grant = try RecoveryGrant(raw: raw)
        XCTAssertEqual(grant.grantType, "onym-unban-grant-v1")
        XCTAssertEqual(grant.caseId, "")
        XCTAssertEqual(grant.claimId, "claim-1")
        XCTAssertEqual(grant.grantee, "onym:key:test")
        XCTAssertEqual(grant.raw, raw)

        let canonical = #"{"authority":"onym:component:authority","claimId":"claim-1","grantType":"onym-unban-grant-v1","grantVersion":1,"grantee":"onym:key:test","issuedAt":"2026-08-09T00:00:00Z"}"#
        let expected = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try grant.reference(), expected)
    }

    /// The reference must equal SHA-256 over the server's canonical
    /// form: every field except `signature`, keys in UTF-8 byte order.
    /// The order pins the `grantVersion` < `grantee` case ('V' < 'e'
    /// by byte, the opposite of a case-insensitive sort) — the exact
    /// spot where a wrong canonicalization would diverge from serde.
    func testGrantReferenceMatchesTheCanonicalBytesHash() throws {
        let grant = try RecoveryGrant(raw: Data(Self.grantJSON.utf8))
        let canonical = #"{"authority":"onym:component:authority","caseId":"case-1","grantType":"onym-recovery-grant-v1","grantVersion":1,"grantee":"onym:key:test","issuedAt":"2026-08-09T00:00:00Z"}"#
        let expected = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try grant.reference(), expected)
    }

    // MARK: The grant against the reference Authority's bytes

    /// Produced by the reference Authority's `issue_grant`
    /// (`authority/src/recovery.rs`, onym-moderation#28) with a fixed
    /// key (seed 0x07 × 32) and a fixed clock: the exact signed bytes
    /// a device would receive, and the exact `grant_ref` the authority
    /// recorded for them. If either side's canonicalization drifts,
    /// this is what fails.
    private static let serverGrantJSON = #"{"grantType":"onym-recovery-grant-v1","grantVersion":1,"caseId":"case-11111111-2222-3333-4444-555555555555","grantee":"npub1granteegranteegranteegranteegranteegranteegrantee","authority":"authority.example","issuedAt":"2025-08-09T06:13:20Z","signature":"KKfCE9ub1yVm9XpPya9R/bP4NcEmwxjpBWKYJ+mfgwboHITFuPdzGYoOpImIJBsXFROta4Zr1erxnzz9O46VBw=="}"#
    private static let serverGrantRef =
        "e5cabc809d33e6216cb18d9282e9f6d9ca51dea46843e431b2a28216f0dfdd72"

    private static let serverUnbanGrantJSON = #"{"grantType":"onym-unban-grant-v1","grantVersion":1,"claimId":"claim-1","grantee":"onym:key:g","authority":"onym:component:a","issuedAt":"2025-12-06T05:46:40Z","signature":"JBa9BruZ1xc1ekZrJKF4qrFg06UDpqotwdYM43mPtFDEgW35BD1Q9tICt/N5V915a9iyQeI0jjX81zrORhTzDA=="}"#
    private static let serverUnbanGrantRef =
        "fea6391989b8a2784bed76de96faa018f910be9def5d5f50c27038f9e93202e1"

    func testGrantReferenceMatchesServerProducedFixture() throws {
        let grant = try RecoveryGrant(raw: Data(Self.serverGrantJSON.utf8))
        XCTAssertEqual(grant.version, 1)
        XCTAssertEqual(grant.caseId, "case-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(grant.grantee, "npub1granteegranteegranteegranteegranteegranteegrantee")
        XCTAssertEqual(grant.authority, "authority.example")
        XCTAssertEqual(grant.issuedAt, "2025-08-09T00:40:00Z")
        XCTAssertEqual(try grant.reference(), Self.serverGrantRef)
    }

    func testUnbanGrantReferenceMatchesServerProducedFixture() throws {
        let grant = try RecoveryGrant(raw: Data(Self.serverUnbanGrantJSON.utf8))
        XCTAssertEqual(grant.grantType, "onym-unban-grant-v1")
        XCTAssertEqual(grant.claimId, "claim-1")
        XCTAssertEqual(grant.grantee, "onym:key:g")
        XCTAssertEqual(grant.authority, "onym:component:a")
        XCTAssertEqual(grant.issuedAt, "2025-12-06T05:46:40Z")
        XCTAssertEqual(try grant.reference(), Self.serverUnbanGrantRef)
    }

    func testGrantThatDoesNotParseIsRefused() {
        XCTAssertThrowsError(try RecoveryGrant(raw: Data("not json".utf8)))
        XCTAssertThrowsError(try RecoveryGrant(raw: Data(#"{"caseId":"c"}"#.utf8)))
    }

    func testGrantWithUnknownVersionIsRefusedByName() {
        let raw = Data(
            Self.grantJSON.replacingOccurrences(
                of: #""grantVersion":1"#,
                with: #""grantVersion":2"#
            ).utf8
        )
        XCTAssertThrowsError(try RecoveryGrant(raw: raw)) { error in
            guard case let ModerationError.grantInvalid(message) = error else {
                return XCTFail("expected grantInvalid, got \(error)")
            }
            XCTAssertTrue(message.contains("version 2"), message)
        }
    }

    /// A legacy grant may omit the version. The decoded property still
    /// defaults to 1, but canonicalization follows the exact raw bytes,
    /// just as the interface does.
    func testGrantWithAbsentVersionDefaultsToOne() throws {
        let raw = Data(
            Self.serverGrantJSON.replacingOccurrences(
                of: #""grantVersion":1,"#,
                with: ""
            ).utf8
        )
        let grant = try RecoveryGrant(raw: raw)
        XCTAssertEqual(grant.version, 1)
        let canonical = #"{"authority":"authority.example","caseId":"case-11111111-2222-3333-4444-555555555555","grantType":"onym-recovery-grant-v1","grantee":"npub1granteegranteegranteegranteegranteegranteegrantee","issuedAt":"2025-08-09T00:40:00Z"}"#
        let expected = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try grant.reference(), expected)
    }

    // MARK: - Session payload

    func testRecoveryPayloadIsDomainSeparatedAndGrantBound() {
        let token = Data("t".utf8)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let recovery = RecoveryRequest.signedPayload(
            deviceToken: token, userKey: "k", grantRef: "g", timestamp: timestamp
        )
        XCTAssertNotEqual(
            recovery,
            GateCheckRequest.signedPayload(
                deviceToken: token, userKey: "k", mandateRef: "g", timestamp: timestamp
            ),
            "a recovery signature must not replay as a gate check"
        )
        XCTAssertNotEqual(
            recovery,
            RecoveryRequest.signedPayload(
                deviceToken: token, userKey: "k", grantRef: "g2", timestamp: timestamp
            ),
            "one signature presents one grant"
        )
    }

    // MARK: - RecoveryResult wire shapes

    func testRecoveryResultDecodesRecoveredWithGate() throws {
        let json = #"{"status":"recovered","gate":{"clear":{}}}"#
        let result = try JSONDecoder().decode(RecoveryResult.self, from: Data(json.utf8))
        XCTAssertEqual(result, .recovered(.clear))
    }

    func testRecoveryResultDecodesMarkInForceWithAndWithoutRoutes() throws {
        let full = #"{"status":"markInForce","authorityContact":"appeals@a.org","newHolderUrl":"https://a.org/new-holder","appealUrl":"https://a.org/appeal"}"#
        let decodedFull = try JSONDecoder().decode(RecoveryResult.self, from: Data(full.utf8))
        XCTAssertEqual(
            decodedFull,
            RecoveryResult.markInForce(
                authorityContact: "appeals@a.org",
                newHolderURL: URL(string: "https://a.org/new-holder"),
                appealURL: URL(string: "https://a.org/appeal")
            )
        )
        let bare = #"{"status":"markInForce","authorityContact":"appeals@a.org"}"#
        let decodedBare = try JSONDecoder().decode(RecoveryResult.self, from: Data(bare.utf8))
        XCTAssertEqual(
            decodedBare,
            RecoveryResult.markInForce(authorityContact: "appeals@a.org", newHolderURL: nil, appealURL: nil)
        )
    }

    /// An unknown status is a response this decode does not speak — a
    /// `DecodingError`, which the real client wraps into
    /// `malformedResponse`, not a defect in the grant.
    func testRecoveryResultRefusesAnUnknownStatus() {
        let json = #"{"status":"cleared-by-someone"}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(RecoveryResult.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
    }

    // MARK: - Enforcement client wire

    func testRecoverPostsTheGrantBytesAndDecodesTheAnswer() async throws {
        let recorded = RecordedBody()
        StubURLProtocol.set { request in
            recorded.record(url: request.url, body: Self.body(of: request))
            return (
                Data(#"{"status":"recovered","gate":{"clear":{}}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let grantRaw = Data(Self.grantJSON.utf8)
        let client = URLSessionEnforcementBackendClient(baseURL: baseURL, session: session)
        let result = try await client.recover(RecoveryRequest(
            deviceToken: Data([0x01]),
            userKey: "onym:key:test",
            grant: grantRaw,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            signature: Data("sig".utf8)
        ))

        XCTAssertEqual(result, .recovered(.clear))
        XCTAssertEqual(recorded.url?.path(), "/v1/recover")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(recorded.body)) as? [String: Any]
        )
        XCTAssertEqual(
            json["grant"] as? String,
            grantRaw.base64EncodedString(),
            "the grant crosses the wire as base64 of the exact signed bytes"
        )
        XCTAssertEqual(json["userKey"] as? String, "onym:key:test")
    }

    // MARK: - Authority client wire

    func testFileRecoveryClaimSignsTheCanonicalBodyMinusSignature() async throws {
        let recorded = RecordedBody()
        StubURLProtocol.set { request in
            recorded.record(url: request.url, body: Self.body(of: request))
            return (
                Data(#"{"claimId":"claim-1","state":"open"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let signer = CapturingSigner()
        let client = URLSessionModerationAuthorityClient(
            baseURL: URL(string: "https://authority.test")!,
            session: session,
            signer: signer,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let claimId = try await client.fileRecoveryClaim(
            contact: "holder@example.org",
            statement: "bought it used"
        )

        XCTAssertEqual(claimId, "claim-1")
        XCTAssertEqual(recorded.url?.path(), "/v1/recovery-claims")
        let body = try XCTUnwrap(recorded.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["grantee"] as? String, "onym:key:test")
        XCTAssertEqual(json["contact"] as? String, "holder@example.org")

        // The signed bytes are the transmitted body minus the
        // signature field, canonical order — the exact form the
        // authority reconstructs and verifies.
        var unsigned = json
        unsigned.removeValue(forKey: "signature")
        let sortedKeys = unsigned.keys.sorted()
        XCTAssertEqual(sortedKeys, ["contact", "grantee", "statement", "timestamp"])
        let expected = "{" + sortedKeys.map { key in
            "\"\(key)\":\"\(unsigned[key] as! String)\""
        }.joined(separator: ",") + "}"
        XCTAssertEqual(signer.lastMessage, Data(expected.utf8))
    }

    func testRecoveryClaimStatusSendsSignedHeadersAndParsesTheGrant() async throws {
        let recordedHeaders = RecordedHeaders()
        let grantB64 = Data(Self.grantJSON.utf8).base64EncodedString()
        StubURLProtocol.set { request in
            recordedHeaders.record(request.allHTTPHeaderFields ?? [:], url: request.url)
            return (
                Data(#"{"claimId":"claim-1","state":"granted","reasoning":"verified","grant":"\#(grantB64)"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let signer = CapturingSigner()
        let client = URLSessionModerationAuthorityClient(
            baseURL: URL(string: "https://authority.test")!,
            session: session,
            signer: signer,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let status = try await client.recoveryClaimStatus(claimId: "claim-1")

        XCTAssertEqual(status.state, "granted")
        XCTAssertEqual(status.reasoning, "verified")
        XCTAssertEqual(status.grant?.caseId, "case-1")
        XCTAssertEqual(recordedHeaders.url?.path(), "/v1/recovery-claims/claim-1")
        XCTAssertEqual(recordedHeaders.headers["X-Onym-Key"], "onym:key:test")
        // The signed message is domain-separated and claim-bound.
        let timestamp = try XCTUnwrap(recordedHeaders.headers["X-Onym-Timestamp"])
        XCTAssertEqual(
            signer.lastMessage,
            Data("recovery-claim-status:claim-1:\(timestamp)".utf8)
        )
    }

    // MARK: - Claim persistence

    func testClaimStoreRoundTripsAndClears() {
        let defaults = UserDefaults(suiteName: "device-recovery-tests")!
        defaults.removePersistentDomain(forName: "device-recovery-tests")
        let store = UserDefaultsRecoveryClaimStore(defaults: defaults)
        XCTAssertNil(store.load(grantee: "onym:key:test"))
        store.save("claim-9", grantee: "onym:key:test")
        XCTAssertEqual(store.load(grantee: "onym:key:test"), "claim-9")
        store.save(nil, grantee: "onym:key:test")
        XCTAssertNil(store.load(grantee: "onym:key:test"))
    }

    /// A claim is answered only to the key that signed it, so a claim
    /// persisted under a previous identity must read as "no claim".
    func testStoredClaimIsInvisibleToADifferentGrantee() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsRecoveryClaimStore(defaults: defaults)

        store.save("claim-1", grantee: "key-old")
        XCTAssertEqual(store.load(grantee: "key-old"), "claim-1")
        XCTAssertNil(store.load(grantee: "key-new"))
    }

    // MARK: - Redemption through the gate repository

    private func gateRepository(
        backend: any EnforcementBackendClient,
        store: any GateStateStore = EphemeralGateStore()
    ) -> GateCheckRepository {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let moderation = ModerationRepository(
            authoritiesFetcher: NoAuthoritiesFetcher(),
            manifestFetcher: RefusingManifestFetcher(),
            mandateStore: EmptyMandateStore(),
            backend: backend,
            authorityClients: StubModerationAuthorityClientFactory(),
            attestation: TokenAttestation(),
            signer: CapturingSigner(),
            clock: { now }
        )
        return GateCheckRepository(
            attestation: TokenAttestation(),
            backend: backend,
            moderation: moderation,
            signer: CapturingSigner(),
            store: store,
            clock: { now }
        )
    }

    func testRedeemingAGrantAdoptsTheReconciledGateAnswer() async throws {
        let store = EphemeralGateStore()
        let gate = gateRepository(
            backend: RecoveryAnsweringBackend(answer: .recovered(.clear)),
            store: store
        )
        let grant = try RecoveryGrant(raw: Data(Self.grantJSON.utf8))

        let redemption = await gate.redeemRecoveryGrant(grant)

        XCTAssertEqual(redemption, .recovered(.operational(openCases: [])))
        let current = await gate.currentStatus()
        XCTAssertEqual(current, .operational(openCases: []), "the gate publishes without a second round trip")
        XCTAssertEqual(store.load()?.lastResult, .clear, "the answer persists as the newest check")
    }

    func testMarkInForcePassesTheRoutesThroughAndMovesNothing() async throws {
        let store = EphemeralGateStore()
        let gate = gateRepository(
            backend: RecoveryAnsweringBackend(answer: .markInForce(
                authorityContact: "appeals@a.org",
                newHolderURL: URL(string: "https://a.org/new-holder"),
                appealURL: nil
            )),
            store: store
        )
        let grant = try RecoveryGrant(raw: Data(Self.grantJSON.utf8))

        let redemption = await gate.redeemRecoveryGrant(grant)

        XCTAssertEqual(redemption, .markInForce(
            authorityContact: "appeals@a.org",
            newHolderURL: URL(string: "https://a.org/new-holder"),
            appealURL: nil
        ))
        XCTAssertNil(store.load(), "a refusal is not a successful check")
    }

    func testABackendRejectionSurfacesItsMessage() async throws {
        let gate = gateRepository(backend: RefusingRecoveryBackend())
        let grant = try RecoveryGrant(raw: Data(Self.grantJSON.utf8))
        let redemption = await gate.redeemRecoveryGrant(grant)
        XCTAssertEqual(redemption, .failed("this grant has already been redeemed"))
    }

    /// The backend would refuse the session anyway; the repository says
    /// why before signing anything, so the holder learns to file a new
    /// claim instead of staring at an opaque rejection.
    func testAGrantForADifferentGranteeIsRefusedLocally() async throws {
        let backend = RecoveryAnsweringBackend(answer: .recovered(.clear))
        let gate = gateRepository(backend: backend)
        let grant = try RecoveryGrant(raw: Data(
            Self.grantJSON.replacingOccurrences(
                of: #""grantee":"onym:key:test""#,
                with: #""grantee":"onym:key:someone-else""#
            ).utf8
        ))

        let redemption = await gate.redeemRecoveryGrant(grant)

        guard case .failed(let message) = redemption else {
            return XCTFail("expected a local refusal, got \(redemption)")
        }
        XCTAssertTrue(message.contains("different identity"), message)
    }

    // MARK: - The claim flow's state machine

    @MainActor
    private func makeFlow(
        store: InMemoryClaimStore = InMemoryClaimStore(),
        grantee: String = "key-1",
        fileClaim: @escaping @MainActor (String, String) async throws -> String = { _, _ in "claim-1" },
        claimStatus: @escaping @MainActor (String) async throws -> RecoveryClaimStatus = { _ in
            RecoveryClaimStatus(state: "open", reasoning: nil, grant: nil)
        },
        redeem: @escaping @MainActor (RecoveryGrant) async -> RecoveryRedemption = { _ in
            .failed("unexpected redeem")
        }
    ) -> DeviceRecoveryFlow {
        DeviceRecoveryFlow(
            claimStore: store,
            grantee: grantee,
            fileClaim: fileClaim,
            claimStatus: claimStatus,
            redeem: redeem
        )
    }

    @MainActor
    func testResumesAPersistedClaimOnlyForItsOwnGrantee() {
        let store = InMemoryClaimStore(claimId: "claim-7", grantee: "key-1")
        XCTAssertEqual(
            makeFlow(store: store, grantee: "key-1").phase,
            .awaitingReview(claimId: "claim-7")
        )
        XCTAssertEqual(makeFlow(store: store, grantee: "key-2").phase, .form)
    }

    @MainActor
    func testFilingRequiresContactAndStatementThenPersistsScoped() async {
        let store = InMemoryClaimStore()
        let flow = makeFlow(store: store, grantee: "key-1")

        await flow.submitClaim(contact: "  ", statement: "x")
        XCTAssertEqual(flow.phase, .form, "a person must be reachable")
        XCTAssertNotNil(flow.errorMessage)

        await flow.submitClaim(contact: "holder@example.org", statement: "bought it used")
        XCTAssertEqual(flow.phase, .awaitingReview(claimId: "claim-1"))
        XCTAssertEqual(store.load(grantee: "key-1"), "claim-1")
        XCTAssertNil(store.load(grantee: "key-2"))
    }

    @MainActor
    func testARefusalShowsReasonsAndStartOverClearsTheClaim() async {
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in
                RecoveryClaimStatus(state: "refused", reasoning: "could not verify", grant: nil)
            }
        )
        await flow.checkClaim()
        XCTAssertEqual(flow.phase, .refused(reasons: "could not verify"))
        XCTAssertNil(store.load(grantee: "key-1"), "a refused claim does not linger")

        flow.startOver()
        XCTAssertEqual(flow.phase, .form)
    }

    @MainActor
    func testAGrantIsRedeemedImmediatelyAndTheClaimRetires() async throws {
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        let grant = try RecoveryGrant(raw: Data(Self.grantJSON.utf8))
        var redeemed = [RecoveryGrant]()
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in
                RecoveryClaimStatus(state: "granted", reasoning: nil, grant: grant)
            },
            redeem: { presented in
                redeemed.append(presented)
                return .recovered(.operational(openCases: []))
            }
        )
        await flow.checkClaim()
        XCTAssertEqual(flow.phase, .recovered)
        XCTAssertEqual(redeemed, [grant], "the grant travels to redemption unaltered")
        XCTAssertNil(store.load(grantee: "key-1"))
    }

    @MainActor
    func testMarkInForceKeepsTheClaimAndStaysCheckable() async throws {
        let grant = try RecoveryGrant(raw: Data(Self.grantJSON.utf8))
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        var polled = 0
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in
                polled += 1
                return RecoveryClaimStatus(state: "granted", reasoning: nil, grant: grant)
            },
            redeem: { _ in
                .markInForce(authorityContact: "appeals@a.org", newHolderURL: nil, appealURL: nil)
            }
        )
        await flow.checkClaim()
        XCTAssertEqual(
            flow.phase,
            .markInForce(authorityContact: "appeals@a.org", newHolderURL: nil, appealURL: nil)
        )
        XCTAssertEqual(store.load(grantee: "key-1"), "claim-1", "the grant on the claim stays redeemable")

        // "Check again" from markInForce must actually poll — the
        // claim id is still in the store.
        await flow.checkClaim()
        XCTAssertEqual(polled, 2)
    }

    @MainActor
    func testACheckInFlightIsNotReentered() async throws {
        let grant = try RecoveryGrant(raw: Data(Self.grantJSON.utf8))
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        var polls = 0
        var redemptions = 0
        var release: CheckedContinuation<Void, Never>?
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in
                polls += 1
                await withCheckedContinuation { release = $0 }
                return RecoveryClaimStatus(state: "granted", reasoning: nil, grant: grant)
            },
            redeem: { _ in
                redemptions += 1
                return .recovered(.operational(openCases: []))
            }
        )
        let first = Task { await flow.checkClaim() }
        // Let the first check reach the suspension inside claimStatus.
        while release == nil { await Task.yield() }
        XCTAssertEqual(flow.phase, .checking(claimId: "claim-1"))

        // The view's `.task` firing here must not start a second poll
        // that would redeem the single-use grant twice.
        await flow.checkClaim()
        XCTAssertEqual(polls, 1)

        release?.resume()
        await first.value
        XCTAssertEqual(polls, 1)
        XCTAssertEqual(redemptions, 1)
        XCTAssertEqual(flow.phase, .recovered)
    }

    @MainActor
    func testAPollErrorLeavesTheClaimActionable() async {
        struct Unreachable: Error {}
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        let flow = makeFlow(store: store, claimStatus: { _ in throw Unreachable() })
        await flow.checkClaim()
        XCTAssertEqual(flow.phase, .awaitingReview(claimId: "claim-1"))
        XCTAssertNotNil(flow.errorMessage)

        // From here the view offers "file a new claim" — the exit for
        // a persisted claim the authority no longer knows.
        flow.startOver()
        XCTAssertEqual(flow.phase, .form)
        XCTAssertNil(flow.errorMessage)
        XCTAssertNil(store.load(grantee: "key-1"))
    }

    @MainActor
    func testAGrantedClaimWithoutBytesStaysAwaiting() async {
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in RecoveryClaimStatus(state: "granted", reasoning: nil, grant: nil) }
        )
        await flow.checkClaim()
        XCTAssertEqual(flow.phase, .awaitingReview(claimId: "claim-1"))
        XCTAssertNotNil(flow.errorMessage)
        XCTAssertEqual(store.load(grantee: "key-1"), "claim-1")
    }

    // MARK: - Support

    private final class RecordedBody: @unchecked Sendable {
        private let lock = NSLock()
        private var _body: Data?
        private var _url: URL?
        func record(url: URL?, body: Data?) {
            lock.withLock { _url = url; _body = body }
        }
        var body: Data? { lock.withLock { _body } }
        var url: URL? { lock.withLock { _url } }
    }

    private final class RecordedHeaders: @unchecked Sendable {
        private let lock = NSLock()
        private var _headers: [String: String] = [:]
        private var _url: URL?
        func record(_ headers: [String: String], url: URL?) {
            lock.withLock { _headers = headers; _url = url }
        }
        var headers: [String: String] { lock.withLock { _headers } }
        var url: URL? { lock.withLock { _url } }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private final class CapturingSigner: ModerationSigner, @unchecked Sendable {
        private let lock = NSLock()
        private var _lastMessage: Data?
        var lastMessage: Data? { lock.withLock { _lastMessage } }
        func userKeyID() async throws -> String { "onym:key:test" }
        func sign(_ message: Data) async throws -> Data {
            lock.withLock { _lastMessage = message }
            return Data("sig".utf8)
        }
    }

    private struct TokenAttestation: DeviceAttestationProvider {
        var isSupported: Bool { true }
        func generateToken() async throws -> Data { Data("token".utf8) }
    }

    private struct RecoveryAnsweringBackend: EnforcementBackendClient {
        let answer: RecoveryResult
        func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
            DeviceEnrollment(deviceBinding: "enrollment-1")
        }
        func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
            InterfaceCountersignature(signature: "unused")
        }
        func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult { .clear }
        func recover(_ request: RecoveryRequest) async throws -> RecoveryResult { answer }
    }

    private struct RefusingRecoveryBackend: EnforcementBackendClient {
        func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
            DeviceEnrollment(deviceBinding: "enrollment-1")
        }
        func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
            InterfaceCountersignature(signature: "unused")
        }
        func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult { .clear }
        func recover(_ request: RecoveryRequest) async throws -> RecoveryResult {
            throw AuthorityClientError.rejected(AuthorityRejection(
                statusCode: 400,
                rawCode: "bad_request",
                message: "this grant has already been redeemed"
            ))
        }
    }

    private final class EphemeralGateStore: GateStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var state: PersistedGateState?
        func load() -> PersistedGateState? { lock.withLock { state } }
        func save(_ state: PersistedGateState?) { lock.withLock { self.state = state } }
    }

    private final class InMemoryClaimStore: RecoveryClaimStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _claimId: String?
        private var _grantee: String?

        init(claimId: String? = nil, grantee: String? = nil) {
            _claimId = claimId
            _grantee = grantee
        }

        func load(grantee: String) -> String? {
            lock.withLock { _grantee == grantee ? _claimId : nil }
        }

        func save(_ claimId: String?, grantee: String) {
            lock.withLock {
                _claimId = claimId
                _grantee = claimId == nil ? nil : grantee
            }
        }
    }

    private final class EmptyMandateStore: MandateStore, @unchecked Sendable {
        func load() -> [MandateRecord] { [] }
        func save(_ records: [MandateRecord]) {}
    }

    private struct NoAuthoritiesFetcher: KnownAuthoritiesFetcher {
        func fetchLatest() async throws -> [AuthorityListing] { [] }
    }

    private struct RefusingManifestFetcher: AuthorityManifestFetcher {
        func fetch(_ listing: AuthorityListing) async throws -> SignedManifest {
            throw ModerationError.notImplemented("unused")
        }
    }
}
