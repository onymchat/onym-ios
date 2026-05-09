import CryptoKit
import XCTest
@testable import OnymIOS

/// Behavioral tests for `JoinRequestApprover` covering PR 4
/// (`recordJoiner` side effect) + PR 5 (`broadcastJoin` fanout) +
/// PR 6 wire-format handoff. Real `IdentityRepository` (isolated
/// keychain), real `GroupRepository` (in-memory), real
/// `InMemoryIntroKeyStore` + `InMemoryIntroRequestStore`, plus a
/// recording `InboxTransport` so we can assert the per-recipient
/// send shape.
@MainActor
final class JoinRequestApproverTests: XCTestCase {

    private var keychain: IdentityKeychainStore!
    private var identity: IdentityRepository!
    private var introKeyStore: InMemoryIntroKeyStore!
    private var introRequestStore: InMemoryIntroRequestStore!
    private var groups: GroupRepository!
    private var transport: ApproverRecordingInboxTransport!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "approver-\(UUID().uuidString)")
        identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        introKeyStore = InMemoryIntroKeyStore()
        introRequestStore = InMemoryIntroRequestStore()
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        transport = ApproverRecordingInboxTransport()
    }

    override func tearDown() async throws {
        try? keychain?.wipeAll()
        keychain = nil
        identity = nil
        introKeyStore = nil
        introRequestStore = nil
        groups = nil
        transport = nil
        try await super.tearDown()
    }

    // MARK: - approve happy path

    func test_approve_sendsSealedInviteAndConsumesRequest() async throws {
        let env = try await seedEnvironment()

        // Pump once: collector reads the seeded request, decodes,
        // populates `pending`.
        await env.approver.pumpOnce()

        let outcome = await env.approver.approve(requestId: env.requestID)
        XCTAssertEqual(outcome, .sent)

        // The approver shipped a sealed invite to the joiner's inbox tag.
        let sends = await transport.sends
        let toJoiner = sends.first { $0.inbox == env.expectedJoinerTag }
        XCTAssertNotNil(toJoiner,
                        "approve must send to the joiner's inbox tag")

        // Request consumed + intro key revoked.
        let remaining = await introRequestStore.current()
        XCTAssertTrue(remaining.isEmpty,
                      "approved request must be consumed from the store")
        let intro = await introKeyStore.find(introPublicKey: env.introPub)
        XCTAssertNil(intro, "intro key must be revoked after approve")
    }

    // MARK: - approve unknown group

    func test_approve_unknownGroup_returnsUnknownGroup() async throws {
        // Seed environment but DON'T insert the group locally — the
        // intro entry references a groupID that the approver can't
        // find in `GroupRepository`.
        let env = try await seedEnvironment(insertGroup: false)
        await env.approver.pumpOnce()
        let outcome = await env.approver.approve(requestId: env.requestID)
        XCTAssertEqual(outcome, .unknownGroup)
        let sends = await transport.sends
        XCTAssertTrue(sends.isEmpty,
                      "no envelopes shipped when the group is unknown")
    }

    // MARK: - approve transport rejected

    func test_approve_transportAcceptedByZero_returnsTransportFailed() async throws {
        await transport.setAcceptedBy(0)
        let env = try await seedEnvironment()
        await env.approver.pumpOnce()
        let outcome = await env.approver.approve(requestId: env.requestID)
        if case .transportFailed = outcome {
            // expected
        } else {
            XCTFail("expected .transportFailed, got \(outcome)")
        }
        let intro = await introKeyStore.find(introPublicKey: env.introPub)
        XCTAssertNotNil(intro,
                        "intro key must NOT be revoked when transport rejects — caller may retry")
    }

    // MARK: - PR 4: recordJoiner side effect

    func test_approve_recordsJoinerInLocalMemberProfiles() async throws {
        let env = try await seedEnvironment()
        await env.approver.pumpOnce()

        let outcome = await env.approver.approve(requestId: env.requestID)
        XCTAssertEqual(outcome, .sent)

        let after = await groups.currentGroups()
        let updated = try XCTUnwrap(after.first { $0.groupIDData == env.groupID })
        let joinerHex = env.joinerBlsPub
            .map { String(format: "%02x", $0) }.joined()
        let profile = try XCTUnwrap(updated.memberProfiles[joinerHex])
        XCTAssertEqual(profile.alias, env.joinerAlias)
        XCTAssertEqual(profile.inboxPublicKey, env.joinerInboxPub)
    }

    // MARK: - PR 5: broadcastJoin fanout

    func test_approve_fanoutTargetsExistingMembersExcludingAdminAndJoiner() async throws {
        // Seed with two existing peer profiles in addition to the
        // creator. broadcastJoin must hit both peers but skip the
        // creator (admin) and the new joiner.
        //
        // Single-identity test setup means joiner inbox == admin
        // inbox, so we can't distinguish "fanout to admin" from
        // "invite to joiner" by tag alone. We assert by total
        // count + per-tag count instead: total sends should be
        // exactly 3 (1 joiner invite + 2 peer announcements). If
        // broadcastJoin failed to skip admin, the joiner tag would
        // appear twice.
        let peerOneInbox = Data(repeating: 0x77, count: 32)
        let peerTwoInbox = Data(repeating: 0x88, count: 32)
        let extraProfiles: [String: MemberProfile] = [
            "77".repeated(48): MemberProfile(alias: "PeerOne", inboxPublicKey: peerOneInbox),
            "88".repeated(48): MemberProfile(alias: "PeerTwo", inboxPublicKey: peerTwoInbox),
        ]
        let env = try await seedEnvironment(extraMemberProfiles: extraProfiles)
        await env.approver.pumpOnce()
        _ = await env.approver.approve(requestId: env.requestID)

        let sends = await transport.sends
        XCTAssertEqual(sends.count, 3,
                       "1 joiner invite + 2 peer announcements; if admin wasn't skipped this would be 4")

        let peerOneTag = ApproverInboxTag.from(peerOneInbox)
        let peerTwoTag = ApproverInboxTag.from(peerTwoInbox)
        XCTAssertEqual(sends.filter { $0.inbox.rawValue == peerOneTag }.count, 1)
        XCTAssertEqual(sends.filter { $0.inbox.rawValue == peerTwoTag }.count, 1)
        XCTAssertEqual(sends.filter { $0.inbox == env.expectedJoinerTag }.count, 1,
                       "joiner gets exactly one envelope (the invitation), not also a fanout copy")
    }

    // MARK: - decline

    func test_decline_dropsRequestAndRevokesKey() async throws {
        let env = try await seedEnvironment()
        await env.approver.pumpOnce()

        await env.approver.decline(requestId: env.requestID)

        let remaining = await introRequestStore.current()
        XCTAssertTrue(remaining.isEmpty,
                      "declined request must be consumed")
        let intro = await introKeyStore.find(introPublicKey: env.introPub)
        XCTAssertNil(intro, "intro key revoked even on decline")
        let sends = await transport.sends
        XCTAssertTrue(sends.isEmpty,
                      "decline ships no envelopes")
    }

    // MARK: - Test fixture builder

    private struct Env {
        let approver: JoinRequestApprover
        let requestID: String
        let groupID: Data
        let introPub: Data
        let joinerBlsPub: Data
        let joinerInboxPub: Data
        let joinerAlias: String
        let adminInboxPub: Data
        let expectedJoinerTag: TransportInboxID
    }

    /// Bootstrap one identity (the admin), mint an intro key for a
    /// fresh group, seed an `IntroRequest` with a sealed
    /// `JoinRequestPayload`, optionally insert the group into the
    /// repository. Returns handles for assertions.
    ///
    /// Single-identity test setup: the same identity plays both
    /// "admin" (sealing the join request envelope, since the test
    /// hasn't got a separate joiner identity) and "joiner inbox"
    /// (the inbox the approver will ship the invite to). The
    /// approver doesn't care; it operates on cryptographic shape.
    private func seedEnvironment(
        insertGroup: Bool = true,
        extraMemberProfiles: [String: MemberProfile] = [:]
    ) async throws -> Env {
        let active = try await identity.bootstrap()
        let ownerID = try await XCTUnwrapAsync(await identity.currentSelectedID())

        let groupID = Data(repeating: 0x42, count: 32)
        let groupIDHex = groupID.map { String(format: "%02x", $0) }.joined()

        // Mint the per-invite intro keypair.
        let introKey = Curve25519.KeyAgreement.PrivateKey()
        let introPub = Data(introKey.publicKey.rawRepresentation)
        let introPrv = introKey.rawRepresentation
        await introKeyStore.save(IntroKeyEntry(
            introPublicKey: introPub,
            introPrivateKey: introPrv,
            ownerIdentityID: ownerID,
            groupId: groupID,
            createdAt: Date()
        ))

        // Build JoinRequestPayload + seal to the intro pubkey using
        // the admin's identity as the signer.
        let joinerInboxPub = active.inboxPublicKey
        let joinerBlsPub = active.blsPublicKey
        let joinerAlias = "Joiner Bob"
        let joinPayload = try JoinRequestPayload(
            joinerInboxPublicKey: joinerInboxPub,
            joinerBlsPublicKey: joinerBlsPub,
            joinerDisplayLabel: joinerAlias,
            groupId: groupID
        )
        let joinPayloadBytes = try JSONEncoder().encode(joinPayload)
        let sealed = try await identity.sealInvitation(
            payload: joinPayloadBytes,
            to: introPub
        )

        let requestID = "req-\(UUID().uuidString)"
        await introRequestStore.record(IntroRequest(
            id: requestID,
            targetIntroPublicKey: introPub,
            payload: sealed,
            receivedAt: Date()
        ))

        if insertGroup {
            // Build admin self-profile so broadcastJoin's "skip admin"
            // logic has something to skip + so peer profiles get
            // exercised.
            let adminBlsHex = active.blsPublicKey
                .map { String(format: "%02x", $0) }.joined()
            var profiles = extraMemberProfiles
            profiles[adminBlsHex] = MemberProfile(
                alias: "Admin",
                inboxPublicKey: active.inboxPublicKey
            )
            let group = ChatGroup(
                id: groupIDHex,
                ownerIdentityID: ownerID,
                name: "Family",
                groupSecret: Data(repeating: 0x55, count: 32),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                members: [],
                memberProfiles: profiles,
                epoch: 0,
                salt: Data(repeating: 0x66, count: 32),
                commitment: Data(repeating: 0x77, count: 32),
                tier: .small,
                groupType: .tyranny,
                adminPubkeyHex: adminBlsHex,
                adminEd25519PubkeyHex: nil,
                isPublishedOnChain: true
            )
            _ = await groups.insert(group)
        }

        let approver = JoinRequestApprover(
            identity: identity,
            introKeyStore: introKeyStore,
            introRequestStore: introRequestStore,
            groupRepository: groups,
            inboxTransport: transport
        )

        return Env(
            approver: approver,
            requestID: requestID,
            groupID: groupID,
            introPub: introPub,
            joinerBlsPub: joinerBlsPub,
            joinerInboxPub: joinerInboxPub,
            joinerAlias: joinerAlias,
            adminInboxPub: active.inboxPublicKey,
            expectedJoinerTag: TransportInboxID(rawValue: ApproverInboxTag.from(joinerInboxPub))
        )
    }
}

// MARK: - Test doubles

/// Recording inbox transport — captures every send + lets tests
/// override `acceptedBy` to drive the transport-rejected path.
private actor ApproverRecordingInboxTransport: InboxTransport {
    private(set) var sends: [(payload: Data, inbox: TransportInboxID)] = []
    private var acceptedBy: Int = 1

    func setAcceptedBy(_ count: Int) { acceptedBy = count }

    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}

    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        sends.append((payload, inbox))
        return PublishReceipt(messageID: UUID().uuidString, acceptedBy: acceptedBy)
    }

    nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream { _ in }
    }

    func unsubscribe(inbox: TransportInboxID) async {}
}

// MARK: - Helpers

/// Mirror of `IntroInboxPump.inboxTag(from:)` (private to the prod
/// type). Test-local copy keeps the formula visible — drift in
/// production breaks here loudly.
private enum ApproverInboxTag {
    static func from(_ inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}

/// Async XCTUnwrap for `nil`-able values resolved from an actor
/// boundary. XCTest doesn't ship one out of the box.
private func XCTUnwrapAsync<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    guard let value else {
        XCTFail("expected non-nil", file: file, line: line)
        throw XCTUnwrapFailedError()
    }
    return value
}

private struct XCTUnwrapFailedError: Error {}
