import CryptoKit
import XCTest
import OnymSDK
@testable import OnymIOS

/// Behavioral tests for `JoinRequestApprover.removeMember` — the
/// admin-side "remove member from a Tyranny group" flow with
/// groupSecret rotation. Gate tests short-circuit before the prover;
/// the happy path + anchor-rejected cases run the REAL
/// `Tyranny.proveUpdate` on the `.small` tier (pattern:
/// `GroupProofGeneratorTests`) against a stub contract transport.
///
/// Mirrors the behavioral shape of onym-android's
/// `GroupMemberRemoverTest`.
@MainActor
final class JoinRequestApproverRemovalTests: XCTestCase {

    private var keychain: IdentityKeychainStore!
    private var identity: IdentityRepository!
    private var groups: GroupRepository!
    private var transport: RemovalRecordingInboxTransport!
    private var relayers: RelayerRepository!
    private var contracts: ContractsRepository!
    private var contractTransport: RemovalStubContractTransport!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "remover-\(UUID().uuidString)")
        identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        transport = RemovalRecordingInboxTransport()
        contractTransport = RemovalStubContractTransport()

        relayers = RelayerRepository(
            fetcher: FakeKnownRelayersFetcher(mode: .succeeds([])),
            store: InMemoryRelayerSelectionStore()
        )
        _ = await relayers.addEndpoint(RelayerEndpoint(
            name: "test",
            url: URL(string: "https://relayer.test.example")!,
            networks: ["testnet"]
        ))
        await relayers.setStrategy(.primary)
        await relayers.setPrimary(url: URL(string: "https://relayer.test.example")!)

        let manifest = ContractsManifest(
            version: 1,
            releases: [
                ContractRelease(
                    release: "v0.0.3",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contracts: [
                        ContractEntry(
                            network: .testnet,
                            type: .tyranny,
                            id: "CTYRANNYTEST00000000000000000000000000000000000000000000"
                        )
                    ]
                )
            ]
        )
        contracts = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(manifest)),
            store: InMemoryAnchorSelectionStore()
        )
        try? await contracts.refresh()
    }

    override func tearDown() async throws {
        try? keychain?.wipeAll()
        keychain = nil
        identity = nil
        groups = nil
        transport = nil
        relayers = nil
        contracts = nil
        contractTransport = nil
        try await super.tearDown()
    }

    // MARK: - Gates

    func test_remove_unknownGroup() async throws {
        let env = try await seedEnvironment(insertGroup: false)
        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: env.victimHex
        )
        XCTAssertEqual(outcome, .unknownGroup)
    }

    func test_remove_cannotRemoveSelf() async throws {
        let env = try await seedEnvironment()
        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: env.adminHex
        )
        XCTAssertEqual(outcome, .cannotRemoveSelf)
    }

    func test_remove_unknownMember() async throws {
        let env = try await seedEnvironment()
        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: String(repeating: "ff", count: 48)
        )
        XCTAssertEqual(outcome, .unknownMember)
    }

    func test_remove_alreadyRemoved() async throws {
        let env = try await seedEnvironment(victimAlreadyRevoked: true)
        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: env.victimHex
        )
        XCTAssertEqual(outcome, .alreadyRemoved)
    }

    func test_remove_memberNotInRoster() async throws {
        // The peer is in `memberProfiles` (app-level directory) but not
        // in the on-chain `members` roster — the tree can't be shrunk
        // around a leaf that was never in it.
        let env = try await seedEnvironment()
        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: env.peerHex
        )
        XCTAssertEqual(outcome, .memberNotInRoster)
    }

    func test_remove_notAdminOfThisGroup_preflight() async throws {
        // The stored group's admin roster entry doesn't match the
        // active identity's derived BLS pub — the pre-flight must
        // catch it before invoking the prover.
        let env = try await seedEnvironment()
        var group = try await currentGroup(env)
        let bogusSecret = Self.fr(9)
        let bogusAdmin = GovernanceMember(
            publicKeyCompressed: try GroupCommitmentBuilder.computePublicKey(secretKey: bogusSecret),
            leafHash: try GroupCommitmentBuilder.computeLeafHash(secretKey: bogusSecret)
        )
        group.members = [bogusAdmin, env.victimMember]
        group.adminPubkeyHex = bogusAdmin.publicKeyCompressed
            .map { String(format: "%02x", $0) }.joined()
        _ = await groups.insert(group)

        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: env.victimHex
        )
        XCTAssertEqual(outcome, .notAdminOfThisGroup)
        let sends = await transport.sends
        XCTAssertTrue(sends.isEmpty, "no envelopes ship when the pre-flight fails")
    }

    // MARK: - Anchor rejected

    func test_remove_anchorRejected_persistsNothing() async throws {
        contractTransport.nextAccepted = false
        let env = try await seedEnvironment()
        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: env.victimHex
        )
        guard case .anchorRejected = outcome else {
            XCTFail("expected .anchorRejected, got \(outcome)")
            return
        }
        let after = try await currentGroup(env)
        XCTAssertEqual(after.epoch, 0, "epoch must NOT advance when the anchor is rejected")
        XCTAssertEqual(after.memberProfiles[env.victimHex]?.revoked, false)
        XCTAssertEqual(after.groupSecret, Data(repeating: 0x55, count: 32))
        XCTAssertEqual(after.members.count, 2)
        let sends = await transport.sends
        XCTAssertTrue(sends.isEmpty, "no envelopes ship when the chain rejects")
    }

    // MARK: - Happy path (real prover)

    func test_remove_happyPath_anchorsPersistsAndFansOut() async throws {
        let env = try await seedEnvironment()

        let outcome = await env.approver.removeMember(
            groupIDHex: env.groupIDHex,
            victimBlsHex: env.victimHex
        )
        XCTAssertEqual(outcome, .sent)

        // The relayer saw exactly one update_commitment.
        XCTAssertEqual(contractTransport.calls.count, 1)

        // ─── persisted state ────────────────────────────────────────
        let after = try await currentGroup(env)
        XCTAssertEqual(after.epoch, 1, "epoch advances by 1")
        XCTAssertFalse(
            after.members.contains { $0.publicKeyCompressed == env.victimMember.publicKeyCompressed },
            "victim leaves the on-chain roster"
        )
        XCTAssertEqual(after.members.count, 1)
        XCTAssertNotEqual(after.groupSecret, Data(repeating: 0x55, count: 32),
                          "groupSecret rotates to fresh random bytes")
        XCTAssertEqual(after.groupSecret.count, 32)
        XCTAssertNotEqual(after.salt, Data(repeating: 0x66, count: 32), "salt rotates")
        XCTAssertEqual(after.commitment?.count, 32)
        // Victim tombstoned, NOT deleted; peer untouched. The tombstone
        // carries the removal epoch so receive-side decisions stay
        // order-independent (MemberProfile.statusEpoch).
        XCTAssertEqual(after.memberProfiles[env.victimHex]?.revoked, true)
        XCTAssertEqual(after.memberProfiles[env.victimHex]?.statusEpoch, 1)
        XCTAssertEqual(after.memberProfiles[env.peerHex]?.revoked, false)

        // ─── fanout ─────────────────────────────────────────────────
        // Two envelopes: victim (secret-free) + peer (with secrets);
        // the admin's own inbox is skipped.
        let sends = await transport.sends
        XCTAssertEqual(sends.count, 2)

        let victimTag = Self.inboxTag(env.victimInboxPub)
        let peerTag = Self.inboxTag(env.peerInboxPub)

        let victimSend = try XCTUnwrap(sends.first { $0.inbox.rawValue == victimTag })
        let victimPayload = try Self.open(
            envelope: victimSend.payload,
            with: env.victimInboxKey
        )
        XCTAssertEqual(victimPayload.removedBlsHex, env.victimHex)
        XCTAssertEqual(victimPayload.epoch, 1)
        XCTAssertEqual(victimPayload.commitment, after.commitment)
        XCTAssertNil(victimPayload.groupSecretNew, "victim never learns the rotated secret")
        XCTAssertNil(victimPayload.saltNew, "victim never learns the rotated salt")

        let peerSend = try XCTUnwrap(sends.first { $0.inbox.rawValue == peerTag })
        let peerPayload = try Self.open(
            envelope: peerSend.payload,
            with: env.peerInboxKey
        )
        XCTAssertEqual(peerPayload.removedBlsHex, env.victimHex)
        XCTAssertEqual(peerPayload.epoch, 1)
        XCTAssertEqual(peerPayload.commitment, after.commitment)
        XCTAssertEqual(peerPayload.groupSecretNew, after.groupSecret,
                       "remaining members receive the rotated secret")
        XCTAssertEqual(peerPayload.saltNew, after.salt,
                       "remaining members receive the rotated salt")
    }

    // MARK: - Fixture

    private struct Env {
        let approver: JoinRequestApprover
        let groupIDHex: String
        let adminHex: String
        let victimHex: String
        let victimMember: GovernanceMember
        let victimInboxKey: Curve25519.KeyAgreement.PrivateKey
        let victimInboxPub: Data
        let peerHex: String
        let peerInboxKey: Curve25519.KeyAgreement.PrivateKey
        let peerInboxPub: Data
    }

    /// Bootstrap the admin identity and seed a two-leaf Tyranny group:
    /// the admin (real keys, so `proveUpdate` succeeds) + a synthetic
    /// victim member (canonical Fr leaf from a small test secret). A
    /// third "peer" lives in `memberProfiles` only — the remaining-
    /// member fanout target.
    private func seedEnvironment(
        insertGroup: Bool = true,
        victimAlreadyRevoked: Bool = false
    ) async throws -> Env {
        let active = try await identity.bootstrap()
        let maybeOwnerID = await identity.currentSelectedID()
        let ownerID = try XCTUnwrap(maybeOwnerID)
        // onym:allow-secret-read
        let adminBlsSecret = try await identity.blsSecretKey()
        let adminLeaf = try GroupCommitmentBuilder.computeLeafHash(secretKey: adminBlsSecret)
        let adminHex = active.blsPublicKey.map { String(format: "%02x", $0) }.joined()

        // Victim: synthetic-but-canonical member (leaf must be a valid
        // Fr for the FFI merkle root, so derive it from a tiny secret).
        let victimSecret = Self.fr(7)
        let victimMember = GovernanceMember(
            publicKeyCompressed: try GroupCommitmentBuilder.computePublicKey(secretKey: victimSecret),
            leafHash: try GroupCommitmentBuilder.computeLeafHash(secretKey: victimSecret)
        )
        let victimHex = victimMember.publicKeyCompressed
            .map { String(format: "%02x", $0) }.joined()
        let victimInboxKey = Curve25519.KeyAgreement.PrivateKey()
        let victimInboxPub = Data(victimInboxKey.publicKey.rawRepresentation)

        // Peer: profile-only remaining member with a decryptable inbox.
        let peerHex = String(repeating: "77", count: 48)
        let peerInboxKey = Curve25519.KeyAgreement.PrivateKey()
        let peerInboxPub = Data(peerInboxKey.publicKey.rawRepresentation)

        let groupID = Self.fr(0x4242)
        let groupIDHex = groupID.map { String(format: "%02x", $0) }.joined()

        if insertGroup {
            let adminMember = GovernanceMember(
                publicKeyCompressed: active.blsPublicKey,
                leafHash: adminLeaf
            )
            let members = [adminMember, victimMember].sorted {
                $0.publicKeyCompressed.lexicographicallyPrecedes($1.publicKeyCompressed)
            }
            let group = ChatGroup(
                id: groupIDHex,
                ownerIdentityID: ownerID,
                name: "Family",
                groupSecret: Data(repeating: 0x55, count: 32),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                members: members,
                memberProfiles: [
                    adminHex: MemberProfile(
                        alias: "Admin",
                        inboxPublicKey: active.inboxPublicKey,
                        sendingPubkey: active.stellarPublicKey
                    ),
                    victimHex: MemberProfile(
                        alias: "Victim",
                        inboxPublicKey: victimInboxPub,
                        sendingPubkey: Data(repeating: 0xE1, count: 32),
                        revoked: victimAlreadyRevoked
                    ),
                    peerHex: MemberProfile(
                        alias: "Peer",
                        inboxPublicKey: peerInboxPub,
                        sendingPubkey: Data(repeating: 0xE2, count: 32)
                    ),
                ],
                epoch: 0,
                salt: Data(repeating: 0x66, count: 32),
                commitment: Data(repeating: 0x77, count: 32),
                tier: .small,
                groupType: .tyranny,
                adminPubkeyHex: adminHex,
                adminEd25519PubkeyHex: nil,
                isPublishedOnChain: true
            )
            _ = await groups.insert(group)
        }

        let chainTransport = contractTransport!
        let approver = JoinRequestApprover(
            identity: identity,
            introKeyStore: InMemoryIntroKeyStore(),
            introRequestStore: InMemoryIntroRequestStore(),
            groupRepository: groups,
            inboxTransport: transport,
            relayers: relayers,
            contracts: contracts,
            networkPreference: RemovalStaticNetworkPreference(value: .testnet),
            makeContractTransport: { _ in chainTransport }
        )

        return Env(
            approver: approver,
            groupIDHex: groupIDHex,
            adminHex: adminHex,
            victimHex: victimHex,
            victimMember: victimMember,
            victimInboxKey: victimInboxKey,
            victimInboxPub: victimInboxPub,
            peerHex: peerHex,
            peerInboxKey: peerInboxKey,
            peerInboxPub: peerInboxPub
        )
    }

    private func currentGroup(_ env: Env) async throws -> ChatGroup {
        let all = await groups.currentGroups()
        return try XCTUnwrap(all.first { $0.id == env.groupIDHex })
    }

    // MARK: - Helpers

    /// Decrypt a sealed removal envelope with the recipient's inbox
    /// private key and decode the `MemberRemovalPayload`.
    private static func open(
        envelope: Data,
        with key: Curve25519.KeyAgreement.PrivateKey
    ) throws -> MemberRemovalPayload {
        let plaintext = try IdentityRepository.decryptSealedEnvelope(
            envelopeBytes: envelope,
            recipientX25519PrivateKey: key
        )
        return try JSONDecoder().decode(MemberRemovalPayload.self, from: plaintext)
    }

    /// Mirror of `IntroInboxPump.inboxTag(from:)`.
    private static func inboxTag(_ inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 32-byte BE encoding of a small u64 — a canonical Fr scalar.
    private static func fr(_ value: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            bytes[31 - i] = UInt8((value >> (i * 8)) & 0xFF)
        }
        return Data(bytes)
    }
}

// MARK: - Test doubles

/// Recording inbox transport — captures every send.
private actor RemovalRecordingInboxTransport: InboxTransport {
    private(set) var sends: [(payload: Data, inbox: TransportInboxID)] = []

    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}

    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        sends.append((payload, inbox))
        return PublishReceipt(messageID: UUID().uuidString, acceptedBy: 1)
    }

    nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream { _ in }
    }

    func unsubscribe(inbox: TransportInboxID) async {}
}

/// Stub `SEPContractTransport` — records every invocation, returns
/// `accepted = true` by default; tests flip `nextAccepted` to drive
/// the rejected path.
private final class RemovalStubContractTransport: SEPContractTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _nextAccepted = true
    private var _calls: [String] = []

    var nextAccepted: Bool {
        get { lock.withLock { _nextAccepted } }
        set { lock.withLock { _nextAccepted = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }

    func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ invocation: SEPContractInvocation<Payload>,
        responseType: Response.Type
    ) async throws -> Response {
        lock.withLock { _calls.append(invocation.function) }
        let response = SEPSubmissionResponse(
            accepted: nextAccepted,
            transactionHash: nextAccepted ? "0xstubhash" : nil,
            message: nextAccepted ? nil : "stub rejected"
        )
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

/// Static `NetworkPreferenceProviding` for tests.
private struct RemovalStaticNetworkPreference: NetworkPreferenceProviding, Sendable {
    let value: AppNetwork
    func current() -> AppNetwork { value }
}
