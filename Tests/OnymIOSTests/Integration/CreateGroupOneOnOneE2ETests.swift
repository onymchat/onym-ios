import Foundation
import XCTest
@testable import OnymIOS

/// End-to-end integration test for the **1-on-1 dialog** Create Group
/// flow against the deployed onym-relayer + Stellar testnet's
/// `sep-oneonone` contract. Skipped by default — opt in via the same
/// env wiring as `CreateGroupTyrannyE2ETests`:
///
/// ```sh
/// ONYM_INTEGRATION=1 \
/// ONYM_RELAYER_URL=https://relayer.onym.chat \
/// ONYM_RELAYER_AUTH_TOKEN=<bearer> \
/// xcodebuild test \
///   -only-testing:OnymIOSTests/CreateGroupOneOnOneE2ETests \
///   …
/// ```
///
/// Mirrors the Tyranny E2E test surface: real `IdentityRepository`
/// (BIP39-restored, isolated keychain), real `OnymGroupProofGenerator`
/// (the OneOnOne PLONK proof — same ~1601-byte raw shape as Tyranny,
/// also runs in a couple of seconds on simulator), real
/// `URLSessionSEPContractTransport` posting to the deployed relayer,
/// real GitHub-Releases-fetched contracts manifest. Inbox transport is
/// faked — invitation send is covered by `CreateGroupInteractorTests`.
///
/// ## OneOnOne specifics asserted here
///
/// - The chain payload is `sep-oneonone`-shaped: no `tier`, no
///   `admin_pubkey_commitment`, 2-element PI vector
///   `[commitment, Fr(0)]`. The wire schema is verified by
///   `SEPContractClientTests`; this test just exercises that the
///   relayer + chain accept the payload end-to-end.
/// - The on-chain `CommitmentEntry` for OneOnOne carries
///   `commitment` + `epoch` + `timestamp` only (no `tier`, no `active`).
/// - The local `ChatGroup` has 2 members (creator + ephemeral peer)
///   and `adminPubkeyHex == nil` (1-on-1 has no admin).
/// - The peer's BLS Fr scalar is minted client-side and shipped
///   inside the invitation envelope — that side of the loop isn't
///   verified here (no real receiver), but the local group state
///   confirms the founding ceremony ran with both secrets.
@MainActor
final class CreateGroupOneOnOneE2ETests: XCTestCase {

    private static let defaultRelayerURL = URL(string: "https://relayer.onym.chat")!
    private static let testMnemonic =
        "legal winner thank year wave sausage worth useful legal winner thank yellow"

    private var keychain: IdentityKeychainStore!
    private var identity: IdentityRepository!

    override func setUp() async throws {
        try await super.setUp()
        try requireIntegrationGate()

        keychain = IdentityKeychainStore(
            testNamespace: "oneonone-e2e-\(UUID().uuidString)"
        )
        identity = IdentityRepository(
            keychain: keychain,
            selectionStore: .inMemory()
        )
        _ = try await identity.restore(mnemonic: Self.testMnemonic)
    }

    override func tearDown() async throws {
        try? keychain?.wipeAll()
        keychain = nil
        identity = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Happy path. Anchors a 1-on-1 group on testnet with one
    /// (paste-only) peer invitee, then reads the commitment back via
    /// `get_commitment` and asserts the round-trip.
    func test_create_oneOnOne_anchorsOnTestnet_andRoundTripsCommitment() async throws {
        let env = try await buildEnvironment()
        let interactor = env.makeInteractor(inboxTransport: FakeInboxTransport())

        // Random 32-byte X25519 stand-in for the peer's inbox key. The
        // interactor only validates length; the relayer doesn't see this
        // value (it's used to derive the inbox tag for the sealed
        // envelope, which FakeInboxTransport accepts unconditionally).
        let peerInbox = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        let group = try await interactor.create(
            governanceType: .oneOnOne,
            name: "e2e-1v1-\(shortID())",
            invitees: [peerInbox]
        )

        XCTAssertTrue(group.isPublishedOnChain,
                      "group must be flagged as anchored after a successful create_group")
        XCTAssertEqual(group.groupType, .oneOnOne)
        XCTAssertEqual(group.tier, .small,
                       "OneOnOne is fixed-depth — `tier` is `.small` by convention")
        XCTAssertEqual(group.epoch, 0)
        XCTAssertEqual(group.members.count, 2,
                       "creator + ephemeral peer = 2 members in the founding roster")
        XCTAssertNil(group.adminPubkeyHex,
                     "1-on-1 has no admin — adminPubkeyHex stays nil")
        XCTAssertEqual(group.commitment?.count, 32,
                       "commitment must be the 32B Poseidon scalar")

        // Round-trip: read the on-chain entry back and assert the
        // commitment matches what we stored locally. The OneOnOne
        // CommitmentEntry shape is `commitment` + `epoch` + `timestamp`
        // — `tier` and `active` are nil for this contract type.
        let onChain = try await env.client.getCommitment(groupID: group.groupIDData)
        XCTAssertEqual(onChain.commitment, group.commitment)
        XCTAssertEqual(onChain.epoch, 0)
        XCTAssertNotNil(onChain.timestamp,
                        "OneOnOne CommitmentEntry surfaces timestamp")
        XCTAssertNil(onChain.tier,
                     "OneOnOne CommitmentEntry has no `tier` field")
        XCTAssertNil(onChain.active,
                     "OneOnOne CommitmentEntry has no `active` field — only democracy/oligarchy do")
    }

    // MARK: - Environment

    private struct E2EEnvironment {
        let identity: IdentityRepository
        let relayers: RelayerRepository
        let contracts: ContractsRepository
        let groups: GroupRepository
        let networkPreference: any NetworkPreferenceProviding
        let proofGenerator: any GroupProofGenerator
        let makeContractTransport: @Sendable (URL) -> any SEPContractTransport
        /// Bound to the resolved oneonone contract — used by the
        /// post-create read-back assertion.
        let client: SEPContractClient

        @MainActor
        func makeInteractor(inboxTransport: any InboxTransport) -> CreateGroupInteractor {
            CreateGroupInteractor(
                identity: identity,
                relayers: relayers,
                contracts: contracts,
                groups: groups,
                networkPreference: networkPreference,
                proofGenerator: proofGenerator,
                inboxTransport: inboxTransport,
                makeContractTransport: makeContractTransport
            )
        }
    }

    @MainActor
    private func buildEnvironment() async throws -> E2EEnvironment {
        let token = try requireEnv("ONYM_RELAYER_AUTH_TOKEN")
        let relayerURL = URL(
            string: ProcessInfo.processInfo.environment["ONYM_RELAYER_URL"]
                ?? Self.defaultRelayerURL.absoluteString
        )!

        let relayers = RelayerRepository(
            fetcher: FakeKnownRelayersFetcher(mode: .succeeds([])),
            store: InMemoryRelayerSelectionStore()
        )
        _ = await relayers.addEndpoint(RelayerEndpoint(
            name: "e2e",
            url: relayerURL,
            networks: ["testnet"]
        ))
        await relayers.setStrategy(.primary)
        await relayers.setPrimary(url: relayerURL)

        // Real GitHub Releases fetch — picks up whichever oneonone
        // contract is currently published. Robust to contracts releases
        // without recompiling the test.
        let contracts = ContractsRepository(
            fetcher: GitHubReleasesContractsManifestFetcher(),
            store: InMemoryAnchorSelectionStore()
        )
        try await contracts.refresh()

        let key = AnchorSelectionKey(network: .testnet, type: .oneonone)
        guard let binding = await contracts.binding(for: key) else {
            throw XCTSkip(
                "No oneonone contract is published in the manifest yet — " +
                "cut a contracts release with at least one testnet oneonone entry."
            )
        }

        let groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        let networkPreference = StaticNetworkPreference(value: .testnet)

        let makeContractTransport: @Sendable (URL) -> any SEPContractTransport = { url in
            URLSessionSEPContractTransport(endpoint: url, authToken: token)
        }

        // Direct client for the read-back assertion. Bypasses
        // RelayerRepository.selectURL because the test already has the URL.
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .oneOnOne,
            network: .testnet,
            transport: makeContractTransport(relayerURL)
        )

        return E2EEnvironment(
            identity: identity,
            relayers: relayers,
            contracts: contracts,
            groups: groups,
            networkPreference: networkPreference,
            proofGenerator: OnymGroupProofGenerator(),
            makeContractTransport: makeContractTransport,
            client: client
        )
    }

    // MARK: - Helpers

    private func requireIntegrationGate() throws {
        // Same gate as CreateGroupTyrannyE2ETests — release.yml wires
        // ONYM_INTEGRATION + ONYM_RELAYER_AUTH_TOKEN via
        // `xcrun simctl spawn booted launchctl setenv` so this runs in
        // CI; locally set them in the shell environment.
        guard ProcessInfo.processInfo.environment["ONYM_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "Set ONYM_INTEGRATION=1 (and ONYM_RELAYER_AUTH_TOKEN) to run this test."
            )
        }
    }

    private func requireEnv(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw XCTSkip("\(name) env var is required for this test.")
        }
        return value
    }

    /// Short suffix for the group `name` so concurrent test-runs don't
    /// collide in relayer logs. The interactor mints a random 32-byte
    /// canonical-Fr `groupID` per run, so on-chain collisions are
    /// already ruled out.
    private func shortID() -> String {
        UUID().uuidString.prefix(8).lowercased()
    }
}
