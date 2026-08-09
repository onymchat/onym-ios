import XCTest
@testable import OnymModeration
import OnymModerationUI

/// Device recovery: the grant's reference derivation pinned to a
/// server-produced fixture, and the claim flow's phase transitions —
/// the two places a wire mismatch or a UI dead end would show first.
final class DeviceRecoveryTests: XCTestCase {

    // MARK: - The grant against the reference Authority's bytes

    /// Produced by the reference Authority's `issue_grant`
    /// (`authority/src/recovery.rs`, onym-moderation#28) with a fixed
    /// key (seed 0x07 × 32) and a fixed clock: the exact signed bytes
    /// a device would receive, and the exact `grant_ref` the authority
    /// recorded for them. If either side's canonicalization drifts,
    /// this is what fails.
    private static let serverGrantJSON = #"{"grantVersion":1,"caseId":"case-11111111-2222-3333-4444-555555555555","grantee":"npub1granteegranteegranteegranteegranteegranteegrantee","authority":"authority.example","issuedAt":"2025-08-09T00:40:00Z","signature":"7o/U1cs4JTzVth3wT5RUgQn0aXKQC+Ry1/SmXwRFTiEM9p4wxapCFAlh6fJoZE/udLLqd5iPf/9HJNRdPdy+AA=="}"#
    private static let serverGrantRef =
        "1451700a69ca305002fadf747e297cd30f22c02126037d1c466b569af0c6f781"

    func testGrantReferenceMatchesServerProducedFixture() throws {
        let grant = try RecoveryGrant(raw: Data(Self.serverGrantJSON.utf8))
        XCTAssertEqual(grant.version, 1)
        XCTAssertEqual(grant.caseId, "case-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(grant.grantee, "npub1granteegranteegranteegranteegranteegranteegrantee")
        XCTAssertEqual(grant.authority, "authority.example")
        XCTAssertEqual(grant.issuedAt, "2025-08-09T00:40:00Z")
        XCTAssertEqual(try grant.reference(), Self.serverGrantRef)
    }

    func testGrantWithUnknownVersionIsRefusedByName() {
        let raw = Data(
            Self.serverGrantJSON.replacingOccurrences(
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

    /// The authority's decoder defaults an absent version to 1
    /// (`#[serde(default = "one")]`); the client must derive the same
    /// signing bytes either way, or an older-shaped grant would fail
    /// redemption.
    func testGrantWithAbsentVersionDefaultsToOne() throws {
        let raw = Data(
            Self.serverGrantJSON.replacingOccurrences(
                of: #""grantVersion":1,"#,
                with: ""
            ).utf8
        )
        let grant = try RecoveryGrant(raw: raw)
        XCTAssertEqual(grant.version, 1)
        XCTAssertEqual(try grant.reference(), Self.serverGrantRef)
    }

    // MARK: - Claim store scoping

    func testStoredClaimIsInvisibleToADifferentGrantee() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsRecoveryClaimStore(defaults: defaults)

        store.save("claim-1", grantee: "key-old")
        XCTAssertEqual(store.load(grantee: "key-old"), "claim-1")
        XCTAssertNil(store.load(grantee: "key-new"))

        store.save(nil, grantee: "key-old")
        XCTAssertNil(store.load(grantee: "key-old"))
    }

    // MARK: - Flow phase transitions

    private final class InMemoryClaimStore: RecoveryClaimStore, @unchecked Sendable {
        private var claimId: String?
        private var grantee: String?

        init(claimId: String? = nil, grantee: String? = nil) {
            self.claimId = claimId
            self.grantee = grantee
        }

        func load(grantee: String) -> String? {
            guard self.grantee == grantee else { return nil }
            return claimId
        }

        func save(_ claimId: String?, grantee: String) {
            self.claimId = claimId
            self.grantee = claimId == nil ? nil : grantee
        }
    }

    private static func grant() throws -> RecoveryGrant {
        try RecoveryGrant(raw: Data(serverGrantJSON.utf8))
    }

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
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        XCTAssertEqual(
            makeFlow(store: store, grantee: "key-1").phase,
            .awaitingReview(claimId: "claim-1")
        )
        XCTAssertEqual(makeFlow(store: store, grantee: "key-2").phase, .form)
    }

    @MainActor
    func testFilingSavesTheClaimScopedToTheGrantee() async {
        let store = InMemoryClaimStore()
        let flow = makeFlow(store: store, grantee: "key-1")
        await flow.submitClaim(contact: "me@example.com", statement: "bought used")
        XCTAssertEqual(flow.phase, .awaitingReview(claimId: "claim-1"))
        XCTAssertEqual(store.load(grantee: "key-1"), "claim-1")
        XCTAssertNil(store.load(grantee: "key-2"))
    }

    @MainActor
    func testAGrantedClaimRedeemsAndClearsTheStore() async throws {
        let grant = try Self.grant()
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        var redeemed = [RecoveryGrant]()
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in RecoveryClaimStatus(state: "granted", reasoning: nil, grant: grant) },
            redeem: { grant in
                redeemed.append(grant)
                return .recovered(.operational(openCases: []))
            }
        )
        await flow.checkClaim()
        XCTAssertEqual(flow.phase, .recovered)
        XCTAssertEqual(redeemed, [grant])
        XCTAssertNil(store.load(grantee: "key-1"))
    }

    @MainActor
    func testARefusedClaimShowsReasonsAndClearsTheStore() async {
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in
                RecoveryClaimStatus(state: "refused", reasoning: "contact unreachable", grant: nil)
            }
        )
        await flow.checkClaim()
        XCTAssertEqual(flow.phase, .refused(reasons: "contact unreachable"))
        XCTAssertNil(store.load(grantee: "key-1"))
    }

    @MainActor
    func testMarkInForceKeepsTheClaimAndStaysCheckable() async throws {
        let grant = try Self.grant()
        let store = InMemoryClaimStore(claimId: "claim-1", grantee: "key-1")
        var polled = 0
        let flow = makeFlow(
            store: store,
            claimStatus: { _ in
                polled += 1
                return RecoveryClaimStatus(state: "granted", reasoning: nil, grant: grant)
            },
            redeem: { _ in
                .markInForce(authorityContact: "mod@example", newHolderURL: nil, appealURL: nil)
            }
        )
        await flow.checkClaim()
        guard case .markInForce = flow.phase else {
            return XCTFail("expected markInForce, got \(flow.phase)")
        }
        XCTAssertEqual(store.load(grantee: "key-1"), "claim-1")

        // "Check again" from markInForce must actually poll — the
        // claim id is still in the store.
        await flow.checkClaim()
        XCTAssertEqual(polled, 2)
    }

    @MainActor
    func testACheckInFlightIsNotReentered() async throws {
        let grant = try Self.grant()
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
}
