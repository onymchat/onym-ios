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
    // PR 13a: stubs for the on-chain anchor leg.
    private var relayers: RelayerRepository!
    private var contracts: ContractsRepository!
    private var proofGenerator: ApproverStubProofGenerator!
    private var contractTransport: ApproverStubContractTransport!

    override func setUp() async throws {
        try await super.setUp()
        keychain = IdentityKeychainStore(testNamespace: "approver-\(UUID().uuidString)")
        identity = IdentityRepository(keychain: keychain, selectionStore: .inMemory())
        introKeyStore = InMemoryIntroKeyStore()
        introRequestStore = InMemoryIntroRequestStore()
        groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        transport = ApproverRecordingInboxTransport()

        relayers = RelayerRepository(
            fetcher: ApproverNoopRelayerFetcher(),
            store: ApproverInMemoryRelayerStore()
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
            fetcher: ApproverFakeContractsFetcher(manifest: manifest),
            store: ApproverInMemoryContractsStore()
        )
        try? await contracts.refresh()

        proofGenerator = ApproverStubProofGenerator()
        contractTransport = ApproverStubContractTransport()
    }

    override func tearDown() async throws {
        try? keychain?.wipeAll()
        keychain = nil
        identity = nil
        introKeyStore = nil
        introRequestStore = nil
        groups = nil
        transport = nil
        relayers = nil
        contracts = nil
        proofGenerator = nil
        contractTransport = nil
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

        // Request consumed; intro key stays alive so the same QR
        // can welcome additional invitees (issue #111). Inviter
        // re-mints from the Share Invite screen to rotate.
        let remaining = await introRequestStore.current()
        XCTAssertTrue(remaining.isEmpty,
                      "approved request must be consumed from the store")
        let intro = await introKeyStore.find(introPublicKey: env.introPub)
        XCTAssertNotNil(intro,
                        "intro key must survive approve so simultaneous-scan and share-to-many flows still work")
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

    // MARK: - PR 13a anchor failure modes

    func test_approve_outdatedJoinerClient_whenLeafHashMissing() async throws {
        // Joiner shipped without joiner_leaf_hash (pre-PR-13 build).
        // Admin can't anchor; should return .outdatedJoinerClient
        // and NOT consume the request.
        let env = try await seedEnvironment(omitJoinerLeafHash: true)
        await env.approver.pumpOnce()
        let outcome = await env.approver.approve(requestId: env.requestID)
        XCTAssertEqual(outcome, .outdatedJoinerClient)
        let remaining = await introRequestStore.current()
        XCTAssertEqual(remaining.count, 1, "outdated request must NOT be consumed")
        let sends = await transport.sends
        XCTAssertTrue(sends.isEmpty, "no envelopes shipped on outdated-client failure")
    }

    func test_approve_anchorRejected_doesNotConsumeRequest() async throws {
        // Chain returns accepted=false (e.g. proof verification
        // failed on the contract side). Admin should NOT ship the
        // invitation, NOT mutate local state, NOT consume the
        // request. Admin can investigate + retry.
        contractTransport.nextAccepted = false
        let env = try await seedEnvironment()
        await env.approver.pumpOnce()
        let outcome = await env.approver.approve(requestId: env.requestID)
        if case .anchorRejected = outcome {
            // expected
        } else {
            XCTFail("expected .anchorRejected, got \(outcome)")
        }
        let sends = await transport.sends
        XCTAssertTrue(sends.isEmpty,
                      "invitation must NOT ship when chain rejects the proof")
        let remaining = await introRequestStore.current()
        XCTAssertEqual(remaining.count, 1,
                       "rejected request stays in store so admin can retry")
        // Local group state stayed at the original (epoch unchanged,
        // members not extended).
        let after = await groups.currentGroups()
        XCTAssertEqual(after.first?.epoch, 0,
                       "epoch must NOT advance when anchor is rejected")
    }

    func test_approve_notAdminOfThisGroup_whenStoredAdminPubkeyDoesntMatchActiveIdentity() async throws {
        // Simulate the "Alice switched to a different identity, but
        // the group was created by the original Alice" case. The
        // approver's pre-flight should catch this before the SDK
        // proof attempt, surfacing as `.notAdminOfThisGroup` (the
        // user-meaningful error) rather than `.proofFailed` with the
        // cryptic `Poseidon(admin_secret_key) ≠ supplied leaf hash`
        // message.
        let env = try await seedEnvironment()
        // Mutate the persisted group so its first member's BLS
        // pubkey is NOT what the active identity's secret hashes to.
        var groups = await groups.currentGroups()
        guard var group = groups.first(where: { $0.id == env.groupID.map { String(format: "%02x", $0) }.joined() }) else {
            XCTFail("test fixture didn't insert the group"); return
        }
        let bogusAdminMember = GovernanceMember(
            publicKeyCompressed: Data(repeating: 0xEE, count: 48),
            leafHash: Data(repeating: 0xFF, count: 32)
        )
        group.members = [bogusAdminMember]
        group.adminPubkeyHex = bogusAdminMember.publicKeyCompressed
            .map { String(format: "%02x", $0) }.joined()
        _ = await self.groups.insert(group)

        await env.approver.pumpOnce()
        let outcome = await env.approver.approve(requestId: env.requestID)
        XCTAssertEqual(outcome, .notAdminOfThisGroup,
                       "pre-flight must catch identity mismatch before invoking the prover")

        let sends = await transport.sends
        XCTAssertTrue(sends.isEmpty,
                      "no envelopes shipped when admin pre-flight fails")
    }

    // MARK: - decline

    func test_decline_dropsRequestButLeavesIntroKeyAlive() async throws {
        let env = try await seedEnvironment()
        await env.approver.pumpOnce()

        await env.approver.decline(requestId: env.requestID)

        let remaining = await introRequestStore.current()
        XCTAssertTrue(remaining.isEmpty,
                      "declined request must be consumed")
        let intro = await introKeyStore.find(introPublicKey: env.introPub)
        XCTAssertNotNil(intro,
                        "intro key must survive decline so a stranger's scan doesn't burn the slot for intended recipients (issue #111)")
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
        extraMemberProfiles: [String: MemberProfile] = [:],
        omitJoinerLeafHash: Bool = false
    ) async throws -> Env {
        let active = try await identity.bootstrap()
        let ownerID = try await XCTUnwrapAsync(await identity.currentSelectedID())
        // onym:allow-secret-read
        let adminBlsSecret = try await identity.blsSecretKey()
        let adminLeafHash = try GroupCommitmentBuilder.computeLeafHash(secretKey: adminBlsSecret)

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
        // the admin's identity as the signer. In production, joiner
        // and admin are different identities; this single-identity
        // collapse is fine because the approver only inspects
        // cryptographic shape, not party relationship.
        //
        // Single-identity collapse means joiner.bls_pub == admin.bls_pub,
        // which would cause the anchor flow to add a duplicate leaf.
        // Use a synthetic joiner BLS pubkey here so the new tree is
        // distinct from the seed.
        let joinerInboxPub = active.inboxPublicKey
        let joinerBlsPub = Data(repeating: 0xCC, count: 48)
        let joinerLeafHash = Data(repeating: 0xDD, count: 32)
        let joinerAlias = "Joiner Bob"
        let joinPayload = try JoinRequestPayload(
            joinerInboxPublicKey: joinerInboxPub,
            joinerBlsPublicKey: joinerBlsPub,
            joinerLeafHash: omitJoinerLeafHash ? nil : joinerLeafHash,
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
            // Admin must be in the cryptographic roster for the
            // anchor path to find adminIndexOld. Real groups land
            // here via CreateGroupInteractor.
            let adminMember = GovernanceMember(
                publicKeyCompressed: active.blsPublicKey,
                leafHash: adminLeafHash
            )
            let group = ChatGroup(
                id: groupIDHex,
                ownerIdentityID: ownerID,
                name: "Family",
                groupSecret: Data(repeating: 0x55, count: 32),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                members: [adminMember],
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

        // Capture the contractTransport for the closure capture.
        let chainTransport = contractTransport!
        let approver = JoinRequestApprover(
            identity: identity,
            introKeyStore: introKeyStore,
            introRequestStore: introRequestStore,
            groupRepository: groups,
            inboxTransport: transport,
            relayers: relayers,
            contracts: contracts,
            networkPreference: ApproverStaticNetworkPreference(value: .testnet),
            proofGenerator: proofGenerator,
            makeContractTransport: { _ in chainTransport }
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

// MARK: - PR 13a chain-anchor stubs

/// Returns canned `Tyranny.UpdateProof`-shape outputs (160-byte PI
/// bundle / 5 chunks) without invoking the real prover. Optional
/// failure mode for the proof-fails test.
private actor ApproverStubProofGenerator: GroupProofGenerator {
    var nextProofShouldFail: Bool = false
    private(set) var proveUpdateCalls: Int = 0

    func setNextProofShouldFail(_ fail: Bool) { nextProofShouldFail = fail }

    nonisolated func proveCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof {
        // Not used in approver tests — return a deterministic create
        // proof so the protocol conformance is satisfied.
        let frZero = Data(repeating: 0, count: 32)
        return GroupCreateProof(
            proof: Data(repeating: 0xAB, count: 1601),
            publicInputs: [
                Data(repeating: 0xCD, count: 32),
                frZero,
                Data(repeating: 0xEF, count: 32),
                input.groupID,
            ]
        )
    }

    nonisolated func proveUpdate(_ input: GroupProofUpdateInput) throws -> GroupUpdateProof {
        // Synchronous bridge into the actor: read flags via an
        // unsafe sync hop. For test purposes a tiny race here is
        // fine — single-test-actor execution serializes calls.
        return try _proveUpdateSync(input)
    }

    private nonisolated func _proveUpdateSync(_ input: GroupProofUpdateInput) throws -> GroupUpdateProof {
        // Use a semaphore to read the flag synchronously. Fine for
        // tests; the actor's serial executor enforces ordering.
        let dispatch = DispatchSemaphore(value: 0)
        var shouldFail = false
        var calls = 0
        Task { [self] in
            shouldFail = await self.nextProofShouldFail
            calls = await self.proveUpdateCalls
            await self.bumpProveUpdateCalls()
            dispatch.signal()
        }
        dispatch.wait()
        _ = calls
        if shouldFail {
            throw GroupProofGeneratorError.sdkFailure("stub: forced failure")
        }
        // Synthetic 160-byte PI bundle — c_old || epoch_old_be ||
        // c_new || admin_pubkey_commitment || group_id_fr.
        var epochOldBe = Data(count: 32)
        epochOldBe.withUnsafeMutableBytes { buf in
            let bytes = buf.bindMemory(to: UInt8.self)
            var v = input.epochOld.bigEndian
            withUnsafeBytes(of: &v) { src in
                for i in 0..<8 { bytes[24 + i] = src[i] }
            }
        }
        return GroupUpdateProof(
            proof: Data(repeating: 0xAB, count: 1601),
            publicInputs: [
                Data(repeating: 0xC0, count: 32),  // c_old (synthetic)
                epochOldBe,
                Data(repeating: 0xC1, count: 32),  // c_new (synthetic)
                Data(repeating: 0xAD, count: 32),  // admin_pubkey_commitment
                input.groupID,                      // group_id_fr
            ]
        )
    }

    private func bumpProveUpdateCalls() {
        proveUpdateCalls += 1
    }
}

/// Stub `SEPContractTransport` — records every invocation, returns
/// `accepted = true` by default; tests can flip
/// `nextAccepted` to drive the rejected path.
private final class ApproverStubContractTransport: SEPContractTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _nextAccepted: Bool = true
    private var _calls: [String] = []

    var nextAccepted: Bool {
        get { lock.withLock { _nextAccepted } }
        set { lock.withLock { _nextAccepted = newValue } }
    }
    var calls: [String] {
        lock.withLock { _calls }
    }

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
private struct ApproverStaticNetworkPreference: NetworkPreferenceProviding, Sendable {
    let value: AppNetwork
    func current() -> AppNetwork { value }
}

/// In-memory `RelayerSelectionStore` so the test fixture can
/// pre-load a configured endpoint without touching UserDefaults.
private final class ApproverInMemoryRelayerStore: RelayerSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: RelayerConfiguration = .empty
    private var cachedKnownList: [RelayerEndpoint] = []

    func loadConfiguration() -> RelayerConfiguration {
        lock.withLock { configuration }
    }
    func saveConfiguration(_ configuration: RelayerConfiguration) {
        lock.withLock { self.configuration = configuration }
    }
    func loadCachedKnownList() -> [RelayerEndpoint] {
        lock.withLock { cachedKnownList }
    }
    func saveCachedKnownList(_ list: [RelayerEndpoint]) {
        lock.withLock { cachedKnownList = list }
    }
}

/// No-op `KnownRelayersFetcher` — the test fixture pre-populates
/// the configuration via `addEndpoint`, no network needed.
private struct ApproverNoopRelayerFetcher: KnownRelayersFetcher {
    func fetchLatest() async throws -> [RelayerEndpoint] { [] }
}

/// In-memory `AnchorSelectionStore` so the test fixture's
/// `ContractsRepository` doesn't reach for UserDefaults.
private final class ApproverInMemoryContractsStore: AnchorSelectionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var manifest: ContractsManifest?
    private var selections: [AnchorSelectionKey: String] = [:]

    func loadSelections() -> [AnchorSelectionKey: String] {
        lock.withLock { selections }
    }
    func saveSelections(_ selections: [AnchorSelectionKey: String]) {
        lock.withLock { self.selections = selections }
    }
    func loadCachedManifest() -> ContractsManifest? {
        lock.withLock { manifest }
    }
    func saveCachedManifest(_ manifest: ContractsManifest) {
        lock.withLock { self.manifest = manifest }
    }
}

/// Returns a fixed manifest from `fetchLatest`.
private struct ApproverFakeContractsFetcher: ContractsManifestFetcher {
    let manifest: ContractsManifest
    func fetchLatest() async throws -> ContractsManifest { manifest }
}
