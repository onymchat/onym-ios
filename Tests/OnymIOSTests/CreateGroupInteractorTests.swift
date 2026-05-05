import Foundation
import XCTest
@testable import OnymIOS

/// End-to-end tests for the `CreateGroupInteractor` pipeline. Real
/// `IdentityRepository` (Keychain-isolated per test), real
/// `RelayerRepository` + `ContractsRepository` seeded with in-memory
/// fakes, real `SwiftDataGroupStore.inMemory()`. Proof generation and
/// chain transport are stubbed so the suite finishes in <1s — the full
/// real-proof path is exercised by `GroupProofGeneratorTests`
/// already.
@MainActor
final class CreateGroupInteractorTests: XCTestCase {

    // MARK: - Happy path

    func test_create_withNoInvitees_savesGroupAndAnchorsOnChain() async throws {
        let env = await makeTestEnv()
        let interactor = env.makeInteractor()

        let group = try await interactor.create(name: "My Group", invitees: [])

        XCTAssertEqual(group.name, "My Group")
        XCTAssertTrue(group.isPublishedOnChain)
        XCTAssertEqual(group.groupType, .tyranny)
        XCTAssertEqual(group.tier, .small)
        XCTAssertEqual(group.epoch, 0)
        XCTAssertEqual(group.members.count, 1, "creator-only roster at create")

        // Group landed in the repository.
        let stored = await env.groups.snapshots.first { _ in true }
        XCTAssertEqual(stored?.first?.id, group.id)

        // No invitations sent.
        let sends = await env.inboxTransport.sends
        XCTAssertTrue(sends.isEmpty)

        // Chain anchor was POSTed exactly once.
        let invocations = env.contractTransport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.function, "create_group")
    }

    // MARK: - Network preference

    func test_create_anchorsOnTheNetworkFromPreference() async throws {
        // With NetworkPreference = mainnet but no mainnet contract in
        // the manifest, the binding lookup should fail.
        let env = await makeTestEnv(includeTyrannyContract: true, network: .mainnet)
        await assertThrows(
            try await env.makeInteractor().create(name: "G", invitees: []),
            CreateGroupError.noContractBinding(.tyranny)
        )
    }

    func test_create_withTwoInvitees_sendsOneInvitationPerInvitee() async throws {
        let env = await makeTestEnv()
        let interactor = env.makeInteractor()

        // Two valid 32-byte X25519 raw pubkeys (random bytes — IdentityRepository.sealInvitation
        // doesn't actually require valid curve points; CryptoKit only checks length).
        let invitee1 = Data(repeating: 0xAA, count: 32)
        let invitee2 = Data(repeating: 0xBB, count: 32)

        let group = try await interactor.create(
            name: "Friends",
            invitees: [invitee1, invitee2]
        )

        XCTAssertTrue(group.isPublishedOnChain)
        let sends = await env.inboxTransport.sends
        XCTAssertEqual(sends.count, 2, "one invitation per invitee")
        XCTAssertEqual(Set(sends.map(\.inbox.rawValue)).count, 2,
                       "each invitee gets a distinct inbox tag")
    }

    // MARK: - Validation

    func test_create_emptyName_throwsInvalidName() async throws {
        let env = await makeTestEnv()
        await assertThrows(
            try await env.makeInteractor().create(name: "   ", invitees: []),
            CreateGroupError.invalidName
        )
    }

    func test_create_inviteeWrongLength_throwsInvalidInviteeKey() async throws {
        let env = await makeTestEnv()
        await assertThrows(
            try await env.makeInteractor().create(
                name: "G",
                invitees: [Data(repeating: 0x01, count: 16)]  // 16 ≠ 32
            ),
            CreateGroupError.invalidInviteeKey(index: 0)
        )
    }

    // MARK: - Resolution failures

    func test_create_noActiveRelayer_throws() async throws {
        let env = await makeTestEnv(addRelayer: false)
        await assertThrows(
            try await env.makeInteractor().create(name: "G", invitees: []),
            CreateGroupError.noActiveRelayer
        )
    }

    func test_create_noContractBinding_throws() async throws {
        let env = await makeTestEnv(includeTyrannyContract: false)
        await assertThrows(
            try await env.makeInteractor().create(name: "G", invitees: []),
            CreateGroupError.noContractBinding(.tyranny)
        )
    }

    // MARK: - Chain failures

    func test_create_anchorTransportError_throws() async throws {
        let env = await makeTestEnv()
        env.contractTransport.behavior = .throws(SEPError.invalidResponse(statusCode: 502, body: "bad gateway"))
        do {
            _ = try await env.makeInteractor().create(name: "G", invitees: [])
            XCTFail("expected anchorTransport error")
        } catch CreateGroupError.anchorTransport(let msg) {
            XCTAssertTrue(msg.contains("502"), "error message should mention status code")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_create_anchorRejected_throws() async throws {
        let env = await makeTestEnv()
        env.contractTransport.behavior = .response(SEPSubmissionResponse(
            accepted: false,
            transactionHash: nil,
            message: "duplicate group ID"
        ))
        await assertThrows(
            try await env.makeInteractor().create(name: "G", invitees: []),
            CreateGroupError.anchorRejected(message: "duplicate group ID")
        )
    }

    func test_create_invitationSendNotAccepted_throws() async throws {
        let env = await makeTestEnv()
        await env.inboxTransport.setReceiptAcceptedBy(0)

        do {
            _ = try await env.makeInteractor().create(
                name: "G",
                invitees: [Data(repeating: 0xAA, count: 32)]
            )
            XCTFail("expected invitationSendFailed")
        } catch CreateGroupError.invitationSendFailed(let index, _) {
            XCTAssertEqual(index, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - OneOnOne

    func test_create_oneOnOne_anchorsOnOneOnOneContractAndShipsPeerSecret() async throws {
        let env = await makeTestEnv(includeOneOnOneContract: true)
        let interactor = env.makeInteractor()
        let peerInbox = Data(repeating: 0xAA, count: 32)

        let group = try await interactor.create(
            governanceType: .oneOnOne,
            name: "Alice & Bob",
            invitees: [peerInbox]
        )

        // Group has both members, no admin, fixed-depth tier.
        XCTAssertEqual(group.groupType, .oneOnOne)
        XCTAssertEqual(group.members.count, 2, "creator + peer")
        XCTAssertNil(group.adminPubkeyHex, "1-on-1 has no admin")
        XCTAssertEqual(group.tier, .small)
        XCTAssertTrue(group.isPublishedOnChain)

        // Anchored on the OneOnOne contract via `create_group`.
        let invocations = env.contractTransport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.function, "create_group")
        let body = try XCTUnwrap(invocations.first.flatMap {
            try? JSONSerialization.jsonObject(with: $0.payload) as? [String: Any]
        })
        XCTAssertEqual(body["contractType"] as? String, "oneonone")
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertNil(payload["admin_pubkey_commitment"], "no admin field on OneOnOne wire")
        XCTAssertNil(payload["tier"], "no tier field on OneOnOne wire")
        let publicInputs = try XCTUnwrap(payload["publicInputs"] as? [String])
        XCTAssertEqual(publicInputs.count, 2, "OneOnOne ships [commitment, Fr(0)]")

        // One sealed invitation went out to the peer's inbox.
        let sends = await env.inboxTransport.sends
        XCTAssertEqual(sends.count, 1)

        // The sealed payload contains the peer's BLS secret. We can't
        // inspect the sealed bytes (they're AES-GCM-encrypted), but
        // sealInvitation is a passthrough wrapper around AES-GCM seal —
        // peeking at what the interactor handed to `sealInvitation` is
        // out of scope, so we settle for verifying the public-input
        // commitment came from our stub (proves the OneOnOne arm ran).
        XCTAssertNotNil(group.commitment)
        XCTAssertEqual(group.commitment, Data(repeating: 0xEE, count: 32))
    }

    func test_create_oneOnOne_zeroInvitees_throws() async throws {
        let env = await makeTestEnv(includeOneOnOneContract: true)
        await assertThrows(
            try await env.makeInteractor().create(
                governanceType: .oneOnOne,
                name: "Solo",
                invitees: []
            ),
            CreateGroupError.oneOnOneRequiresExactlyOnePeer(got: 0)
        )
    }

    func test_create_oneOnOne_twoInvitees_throws() async throws {
        let env = await makeTestEnv(includeOneOnOneContract: true)
        await assertThrows(
            try await env.makeInteractor().create(
                governanceType: .oneOnOne,
                name: "Crowd",
                invitees: [
                    Data(repeating: 0xAA, count: 32),
                    Data(repeating: 0xBB, count: 32),
                ]
            ),
            CreateGroupError.oneOnOneRequiresExactlyOnePeer(got: 2)
        )
    }

    func test_create_oneOnOne_noContractBinding_throws() async throws {
        let env = await makeTestEnv(includeOneOnOneContract: false)
        await assertThrows(
            try await env.makeInteractor().create(
                governanceType: .oneOnOne,
                name: "G",
                invitees: [Data(repeating: 0xAA, count: 32)]
            ),
            CreateGroupError.noContractBinding(.oneonone)
        )
    }

    // MARK: - Anarchy

    func test_create_anarchy_anchorsOnAnarchyContractAndShipsInvitations() async throws {
        let env = await makeTestEnv(includeAnarchyContract: true)
        let interactor = env.makeInteractor()

        let inviteeKey = Data(repeating: 0xCC, count: 32)
        let group = try await interactor.create(
            governanceType: .anarchy,
            name: "Open Garden",
            invitees: [inviteeKey]
        )

        XCTAssertEqual(group.groupType, .anarchy)
        XCTAssertEqual(group.members.count, 1, "creator-only roster at create time")
        XCTAssertNil(group.adminPubkeyHex, "Anarchy has no admin")
        XCTAssertEqual(group.tier, .small)
        XCTAssertTrue(group.isPublishedOnChain)

        let invocations = env.contractTransport.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.function, "create_group")
        let body = try XCTUnwrap(invocations.first.flatMap {
            try? JSONSerialization.jsonObject(with: $0.payload) as? [String: Any]
        })
        XCTAssertEqual(body["contractType"] as? String, "anarchy")
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertNil(payload["admin_pubkey_commitment"], "no admin field on Anarchy wire")
        XCTAssertEqual((payload["tier"] as? NSNumber)?.intValue, 0, "tier=small=0")
        XCTAssertEqual((payload["member_count"] as? NSNumber)?.intValue, 0,
                       "Anarchy create publishes the documented \"not tracked\" sentinel; the chain learns tier, never the exact roster size at create.")
        let publicInputs = try XCTUnwrap(payload["publicInputs"] as? [String])
        XCTAssertEqual(publicInputs.count, 2, "Anarchy ships [commitment, Fr(0)]")

        // The invitation got sent.
        let sends = await env.inboxTransport.sends
        XCTAssertEqual(sends.count, 1)
    }

    func test_create_anarchy_zeroInvitees_anchorsButSendsNothing() async throws {
        let env = await makeTestEnv(includeAnarchyContract: true)
        let interactor = env.makeInteractor()
        let group = try await interactor.create(
            governanceType: .anarchy,
            name: "Solo Anarchy",
            invitees: []
        )
        XCTAssertTrue(group.isPublishedOnChain)
        let sends = await env.inboxTransport.sends
        XCTAssertTrue(sends.isEmpty, "no invitees → no sends")
    }

    func test_create_anarchy_noContractBinding_throws() async throws {
        let env = await makeTestEnv(includeAnarchyContract: false)
        await assertThrows(
            try await env.makeInteractor().create(
                governanceType: .anarchy,
                name: "G",
                invitees: []
            ),
            CreateGroupError.noContractBinding(.anarchy)
        )
    }

    func test_create_democracy_throws_unsupported() async throws {
        // Anarchy is now supported — the unsupported guardrail still
        // fires for democracy / oligarchy.
        let env = await makeTestEnv()
        await assertThrows(
            try await env.makeInteractor().create(
                governanceType: .democracy,
                name: "G",
                invitees: []
            ),
            CreateGroupError.unsupportedGovernanceType(.democracy)
        )
    }

    // MARK: - Helpers

    private func assertThrows<T: Sendable>(
        _ expression: @autoclosure () async throws -> T,
        _ expected: CreateGroupError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected to throw \(expected), got success", file: file, line: line)
        } catch let error as CreateGroupError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private func makeTestEnv(
        addRelayer: Bool = true,
        includeTyrannyContract: Bool = true,
        includeOneOnOneContract: Bool = false,
        includeAnarchyContract: Bool = false,
        network: AppNetwork = .testnet
    ) async -> CreateGroupTestEnv {
        let env = await CreateGroupTestEnv.make(
            addRelayer: addRelayer,
            includeTyrannyContract: includeTyrannyContract,
            includeOneOnOneContract: includeOneOnOneContract,
            includeAnarchyContract: includeAnarchyContract,
            network: network
        )
        return env
    }
}

// MARK: - Test environment

/// Holds every dependency `CreateGroupInteractor` needs, pre-seeded
/// for the happy path. Each test can mutate `contractTransport.behavior`
/// or the inbox transport's receipt count to exercise specific
/// failures without rebuilding the whole graph.
@MainActor
private final class CreateGroupTestEnv {
    let identity: IdentityRepository
    let relayers: RelayerRepository
    let contracts: ContractsRepository
    let groups: GroupRepository
    let inboxTransport: ConfigurableInboxTransport
    let contractTransport: ConfigurableContractTransport
    let proofGenerator: StubGroupProofGenerator
    let networkPreference: StaticNetworkPreference
    private let keychain: IdentityKeychainStore

    static func make(
        addRelayer: Bool,
        includeTyrannyContract: Bool,
        includeOneOnOneContract: Bool = false,
        includeAnarchyContract: Bool = false,
        network: AppNetwork
    ) async -> CreateGroupTestEnv {
        let keychain = IdentityKeychainStore(
            testNamespace: "create-group-\(UUID().uuidString)"
        )
        let identity = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
        // Use a real BIP39 vector so we get real BLS keys + StrKey AccountID.
        _ = try? await identity.restore(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )

        let relayerStore = InMemoryRelayerSelectionStore()
        let relayers = RelayerRepository(
            fetcher: FakeKnownRelayersFetcher(mode: .succeeds([])),
            store: relayerStore
        )
        if addRelayer {
            _ = await relayers.addEndpoint(RelayerEndpoint(
                name: "test",
                url: URL(string: "https://relayer.test.example")!,
                networks: ["testnet"]
            ))
            await relayers.setStrategy(.primary)
            await relayers.setPrimary(url: URL(string: "https://relayer.test.example")!)
        }

        var contractEntries: [ContractEntry] = []
        if includeTyrannyContract {
            contractEntries.append(ContractEntry(
                network: .testnet,
                type: .tyranny,
                id: "CTYRANNYTEST00000000000000000000000000000000000000000000"
            ))
        }
        if includeOneOnOneContract {
            contractEntries.append(ContractEntry(
                network: .testnet,
                type: .oneonone,
                id: "C1V1CONTRACTTEST000000000000000000000000000000000000000"
            ))
        }
        if includeAnarchyContract {
            contractEntries.append(ContractEntry(
                network: .testnet,
                type: .anarchy,
                id: "CANARCHYCONTRACTTEST00000000000000000000000000000000000"
            ))
        }
        let manifest = ContractsManifest(
            version: 1,
            releases: [
                ContractRelease(
                    release: "v0.0.3",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contracts: contractEntries
                )
            ]
        )
        let contractsStore = InMemoryAnchorSelectionStore()
        let contracts = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(manifest)),
            store: contractsStore
        )
        try? await contracts.refresh()

        // Pre-bind the group repo to the restored identity so the
        // multi-identity filter passes the test fixture's groups
        // through. Without this, snapshots would be filtered to nil
        // → [] and every "group landed in the repo" assert would
        // fail.
        let currentID = await identity.currentSelectedID()
        let groups = GroupRepository(
            store: SwiftDataGroupStore.inMemory(),
            currentIdentityID: currentID
        )

        return CreateGroupTestEnv(
            identity: identity,
            relayers: relayers,
            contracts: contracts,
            groups: groups,
            inboxTransport: ConfigurableInboxTransport(),
            contractTransport: ConfigurableContractTransport(),
            proofGenerator: StubGroupProofGenerator(),
            networkPreference: StaticNetworkPreference(value: network),
            keychain: keychain
        )
    }

    private init(
        identity: IdentityRepository,
        relayers: RelayerRepository,
        contracts: ContractsRepository,
        groups: GroupRepository,
        inboxTransport: ConfigurableInboxTransport,
        contractTransport: ConfigurableContractTransport,
        proofGenerator: StubGroupProofGenerator,
        networkPreference: StaticNetworkPreference,
        keychain: IdentityKeychainStore
    ) {
        self.identity = identity
        self.relayers = relayers
        self.contracts = contracts
        self.groups = groups
        self.inboxTransport = inboxTransport
        self.contractTransport = contractTransport
        self.proofGenerator = proofGenerator
        self.networkPreference = networkPreference
        self.keychain = keychain
    }

    deinit { try? keychain.wipeAll() }

    func makeInteractor() -> CreateGroupInteractor {
        CreateGroupInteractor(
            identity: identity,
            relayers: relayers,
            contracts: contracts,
            groups: groups,
            networkPreference: networkPreference,
            proofGenerator: proofGenerator,
            inboxTransport: inboxTransport,
            makeContractTransport: { [contractTransport] _ in contractTransport }
        )
    }
}

// MARK: - Stubs

/// Returns a deterministic 1601-byte "proof" + per-type PI bundle
/// without actually proving. Skips the ~3.5s real prover so the test
/// suite stays fast.
private struct StubGroupProofGenerator: GroupProofGenerator {
    func proveCreate(_ input: GroupProofCreateInput) throws -> GroupCreateProof {
        switch input.groupType {
        case .tyranny:
            return GroupCreateProof(
                proof: Data(repeating: 0xAB, count: 1601),
                publicInputs: [
                    Data(repeating: 0xCD, count: 32),  // commitment
                    Data(repeating: 0x00, count: 32),  // Fr(0)
                    Data(repeating: 0x42, count: 32),  // admin_pubkey_commitment
                    Data(repeating: 0x77, count: 32),  // group_id_fr
                ]
            )
        case .oneOnOne:
            // Mirror the real OneOnOne SDK shape: raise if peer secret
            // missing so the interactor's OneOnOne branch stays honest
            // in tests.
            guard input.peerBlsSecretKey != nil else {
                throw GroupProofGeneratorError.missingPeerSecret
            }
            return GroupCreateProof(
                proof: Data(repeating: 0xCC, count: 1601),
                publicInputs: [
                    Data(repeating: 0xEE, count: 32),  // commitment
                    Data(repeating: 0x00, count: 32),  // Fr(0)
                ]
            )
        case .anarchy:
            // Mirror the real Anarchy proveMembership-at-epoch-0 shape:
            // 2-element PI like OneOnOne, no admin field. Validate the
            // prover-index guard so the interactor branch stays honest.
            guard input.adminIndex >= 0, input.adminIndex < input.members.count else {
                throw GroupProofGeneratorError.adminIndexOutOfRange(
                    index: input.adminIndex,
                    count: input.members.count
                )
            }
            return GroupCreateProof(
                proof: Data(repeating: 0xDD, count: 1601),
                publicInputs: [
                    Data(repeating: 0xBE, count: 32),  // commitment
                    Data(repeating: 0x00, count: 32),  // Fr(0)
                ]
            )
        default:
            throw GroupProofGeneratorError.notYetSupported(input.groupType)
        }
    }

    /// PR 13a: not exercised in CreateGroupInteractor flows
    /// (CreateGroupInteractor never calls `proveUpdate`), but the
    /// protocol now requires it. Throws `notYetSupported` for every
    /// type — the create-side stubs don't need to model the update
    /// path.
    func proveUpdate(_ input: GroupProofUpdateInput) throws -> GroupUpdateProof {
        throw GroupProofGeneratorError.notYetSupported(input.groupType)
    }
}

/// Recording inbox transport with a configurable acceptedBy count.
/// Different from the existing `FakeInboxTransport` (which forces
/// acceptedBy=1) so we can exercise the "no relay accepted" path.
private actor ConfigurableInboxTransport: InboxTransport {
    struct Send: Sendable {
        let payload: Data
        let inbox: TransportInboxID
    }

    private(set) var sends: [Send] = []
    private var receiptAcceptedBy: Int = 1

    func setReceiptAcceptedBy(_ count: Int) { receiptAcceptedBy = count }

    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}

    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        sends.append(Send(payload: payload, inbox: inbox))
        return PublishReceipt(messageID: "fake-\(UUID().uuidString)", acceptedBy: receiptAcceptedBy)
    }

    nonisolated func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> {
        AsyncStream { _ in }
    }

    func unsubscribe(inbox: TransportInboxID) async {}
}

/// Recording contract transport. `behavior` controls whether the next
/// invocation throws or returns a canned response.
private final class ConfigurableContractTransport: SEPContractTransport, @unchecked Sendable {
    enum Behavior: Sendable {
        case response(SEPSubmissionResponse)
        case `throws`(Error)
    }

    struct Invocation: @unchecked Sendable {
        let function: String
        let payload: Data
    }

    private let lock = NSLock()
    private var _behavior: Behavior = .response(SEPSubmissionResponse(
        accepted: true,
        transactionHash: "0xstub",
        message: nil
    ))
    private var _invocations: [Invocation] = []

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    var invocations: [Invocation] {
        lock.withLock { _invocations }
    }

    func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ invocation: SEPContractInvocation<Payload>,
        responseType: Response.Type
    ) async throws -> Response {
        let encoded = try JSONEncoder().encode(invocation)
        let body = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
        let function = (body?["function"] as? String) ?? "?"
        lock.withLock {
            _invocations.append(Invocation(function: function, payload: encoded))
        }
        switch behavior {
        case .response(let stub):
            let data = try JSONEncoder().encode(stub)
            return try JSONDecoder().decode(Response.self, from: data)
        case .throws(let error):
            throw error
        }
    }
}
