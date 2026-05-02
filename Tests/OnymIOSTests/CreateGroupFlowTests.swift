import XCTest
@testable import OnymIOS

/// View-model tests for `CreateGroupFlow`. The interactor is real but
/// uses the same in-memory environment as `CreateGroupInteractorTests`,
/// so these tests verify the flow's intent dispatch + form validation
/// rather than the pipeline mechanics.
@MainActor
final class CreateGroupFlowTests: XCTestCase {

    // MARK: - Step1 → Step2

    func test_canAdvanceToStep2_requiresNonEmptyNameAndAvailableGovernance() async throws {
        let flow = await makeFlow()
        XCTAssertFalse(flow.canAdvanceToStep2, "empty name blocks advance")
        flow.name = "  "
        XCTAssertFalse(flow.canAdvanceToStep2, "whitespace-only name blocks advance")
        flow.name = "Friends"
        XCTAssertTrue(flow.canAdvanceToStep2)
    }

    func test_unavailableGovernance_blocksAdvance() async throws {
        let flow = await makeFlow()
        flow.name = "Friends"
        flow.governance = .anarchy   // not yet supported
        XCTAssertFalse(flow.canAdvanceToStep2)
    }

    func test_tappedNext_advancesToStep2() async throws {
        let flow = await makeFlow()
        flow.name = "Friends"
        flow.tappedNext()
        XCTAssertEqual(flow.route, .step2)
    }

    func test_tappedNext_isNoOpWhenInvalid() async throws {
        let flow = await makeFlow()
        flow.tappedNext()  // empty name
        XCTAssertEqual(flow.route, .step1)
    }

    // MARK: - InviteByKey

    func test_addInvitee_validHex_appendsAndReturnsToStep2() async throws {
        let flow = await makeFlow()
        flow.route = .inviteByKey
        flow.inviteeInput = String(repeating: "ab", count: 32)  // 64 chars
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.invitees.count, 1)
        XCTAssertEqual(flow.invitees[0].inboxPublicKey, Data(repeating: 0xAB, count: 32))
        XCTAssertEqual(flow.route, .step2)
        XCTAssertNil(flow.inviteeError)
        XCTAssertEqual(flow.inviteeInput, "")
    }

    func test_addInvitee_emptyInput_setsError_doesNotAppend() async throws {
        let flow = await makeFlow()
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.invitees.count, 0)
        XCTAssertNotNil(flow.inviteeError)
        XCTAssertTrue(flow.inviteeError?.contains("Paste") ?? false)
    }

    func test_addInvitee_wrongLength_setsError() async throws {
        let flow = await makeFlow()
        flow.inviteeInput = "abc"
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.invitees.count, 0)
        XCTAssertTrue(flow.inviteeError?.contains("64") ?? false)
    }

    func test_addInvitee_nonHex_setsError() async throws {
        let flow = await makeFlow()
        flow.inviteeInput = String(repeating: "z", count: 64)
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.invitees.count, 0)
        XCTAssertNotNil(flow.inviteeError)
    }

    func test_addInvitee_stripsWhitespace() async throws {
        let flow = await makeFlow()
        // Hex with embedded whitespace — should be cleaned before length check.
        let raw = String(repeating: "ab", count: 32)
        let withSpaces = raw.enumerated().map { i, c in
            i % 8 == 0 ? " \(c)" : "\(c)"
        }.joined()
        flow.inviteeInput = withSpaces
        XCTAssertEqual(flow.inviteeInputCleanedLength, 64)
        XCTAssertTrue(flow.inviteeInputIsValid)
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.invitees.count, 1)
    }

    func test_removeInvitee_removesByIndex() async throws {
        let flow = await makeFlow()
        flow.inviteeInput = String(repeating: "aa", count: 32)
        flow.tappedAddInvitee()
        flow.inviteeInput = String(repeating: "bb", count: 32)
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.invitees.count, 2)
        flow.removeInvitee(at: 0)
        XCTAssertEqual(flow.invitees.count, 1)
        XCTAssertEqual(flow.invitees[0].inboxPublicKey, Data(repeating: 0xBB, count: 32))
    }

    // MARK: - Routing

    func test_tappedInviteByKey_clearsInputAndNavigates() async throws {
        let flow = await makeFlow()
        flow.inviteeInput = "leftover"
        flow.inviteeError = "stale"
        flow.tappedInviteByKey()
        XCTAssertEqual(flow.route, .inviteByKey)
        XCTAssertEqual(flow.inviteeInput, "")
        XCTAssertNil(flow.inviteeError)
    }

    func test_createCTALabel_reflectsInviteeCount() async throws {
        let flow = await makeFlow()
        XCTAssertEqual(flow.createCTALabel, "Create empty group")
        flow.inviteeInput = String(repeating: "aa", count: 32)
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.createCTALabel, "Create with 1 person")
        flow.inviteeInput = String(repeating: "bb", count: 32)
        flow.tappedAddInvitee()
        XCTAssertEqual(flow.createCTALabel, "Create with 2 people")
    }

    // MARK: - onClose

    func test_tappedDone_resetsAndCallsOnClose() async throws {
        let flow = await makeFlow()
        var closedCount = 0
        flow.onClose = { closedCount += 1 }
        flow.name = "stale"
        flow.invitees = [
            OnymInvitee(id: UUID(), inboxPublicKey: Data(repeating: 0, count: 32), displayLabel: "x")
        ]
        flow.route = .success
        flow.tappedDone()
        XCTAssertEqual(closedCount, 1)
        XCTAssertEqual(flow.route, .step1)
        XCTAssertEqual(flow.name, "")
        XCTAssertTrue(flow.invitees.isEmpty)
    }

    // MARK: - Helpers

    private func makeFlow() async -> CreateGroupFlow {
        let env = await CreateGroupFlowTestEnv.make()
        return CreateGroupFlow(interactor: env.interactor)
    }
}

@MainActor
private final class CreateGroupFlowTestEnv {
    let interactor: CreateGroupInteractor
    private let keychain: KeychainStore

    static func make() async -> CreateGroupFlowTestEnv {
        let keychain = KeychainStore(
            service: "chat.onym.ios.identity.tests.flow.\(UUID().uuidString)",
            account: "current"
        )
        let identity = IdentityRepository(keychain: keychain)
        _ = try? await identity.restore(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let relayers = RelayerRepository(
            fetcher: FakeKnownRelayersFetcher(mode: .succeeds([])),
            store: InMemoryRelayerSelectionStore()
        )
        let manifest = ContractsManifest(
            version: 1,
            releases: [ContractRelease(
                release: "v0.0.3",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                contracts: [ContractEntry(network: .testnet, type: .tyranny, id: "CTYRANNYTEST")]
            )]
        )
        let contracts = ContractsRepository(
            fetcher: FakeContractsManifestFetcher(mode: .succeeds(manifest)),
            store: InMemoryAnchorSelectionStore()
        )
        try? await contracts.refresh()

        // Tests in this file only touch flow state — the interactor is
        // never invoked, so an unconfigured contract transport is fine.
        let interactor = CreateGroupInteractor(
            identity: identity,
            relayers: relayers,
            contracts: contracts,
            groups: GroupRepository(store: SwiftDataGroupStore.inMemory()),
            inboxTransport: FlowTestInboxTransport(),
            makeContractTransport: { _ in FlowTestContractTransport() }
        )
        return CreateGroupFlowTestEnv(interactor: interactor, keychain: keychain)
    }

    private init(interactor: CreateGroupInteractor, keychain: KeychainStore) {
        self.interactor = interactor
        self.keychain = keychain
    }

    deinit { try? keychain.wipe() }
}

private struct FlowTestInboxTransport: InboxTransport {
    func connect(to endpoints: [TransportEndpoint]) async {}
    func disconnect() async {}
    func send(_ payload: Data, to inbox: TransportInboxID) async throws -> PublishReceipt {
        PublishReceipt(messageID: "x", acceptedBy: 1)
    }
    func subscribe(inbox: TransportInboxID) -> AsyncStream<InboundInbox> { AsyncStream { _ in } }
    func unsubscribe(inbox: TransportInboxID) async {}
}

private struct FlowTestContractTransport: SEPContractTransport {
    func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ invocation: SEPContractInvocation<Payload>,
        responseType: Response.Type
    ) async throws -> Response {
        let stub = SEPSubmissionResponse(accepted: true, transactionHash: nil, message: nil)
        let data = try JSONEncoder().encode(stub)
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
