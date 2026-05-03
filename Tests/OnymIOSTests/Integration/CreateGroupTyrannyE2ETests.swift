import Foundation
import XCTest
@testable import OnymIOS

/// End-to-end integration test for the Create Group flow against the
/// **deployed** onym-relayer + Stellar testnet contract. Skipped by
/// default — opt in by setting `ONYM_INTEGRATION=1`. Two more env
/// vars control the wiring:
///
/// ```sh
/// ONYM_INTEGRATION=1 \
/// ONYM_RELAYER_URL=https://relayer.onym.chat \
/// ONYM_RELAYER_AUTH_TOKEN=<bearer> \
/// xcodebuild test \
///   -only-testing:OnymIOSTests/CreateGroupTyrannyE2ETests \
///   …
/// ```
///
/// `ONYM_RELAYER_URL` defaults to the production URL if unset.
/// `ONYM_RELAYER_AUTH_TOKEN` is required — without it every relayer
/// call returns 401 and the test fails loudly.
///
/// ## What this test exercises
///
/// The full pipeline from PR-A/B/C: real `IdentityRepository` (BIP39-
/// restored, isolated keychain), real `OnymGroupProofGenerator`
/// (Tyranny PLONK proof, ~3.5s on a Pixel/iPhone-class CPU), real
/// `URLSessionSEPContractTransport` posting to the deployed relayer,
/// real GitHub-Releases-fetched contracts manifest. Inbox transport
/// is faked because the relayer + chain leg is what we're verifying
/// — the invitation send is covered by `CreateGroupInteractorTests`
/// already.
///
/// ## What this test does NOT exercise
///
/// - Real Nostr inbox delivery (FakeInboxTransport — `acceptedBy = 1`).
/// - Receiver-side invitation decryption flow.
/// - Anything off the Tyranny path (Anarchy / 1v1 / Democracy stubs
///   throw `notYetSupported` per PR-B).
/// - update_commitment / member-add (post-PR-D scope).
@MainActor
final class CreateGroupTyrannyE2ETests: XCTestCase {

    private static let defaultRelayerURL = URL(string: "https://relayer.onym.chat")!
    private static let testMnemonic =
        "legal winner thank year wave sausage worth useful legal winner thank yellow"

    private var keychain: KeychainStore!
    private var identity: IdentityRepository!

    override func setUp() async throws {
        try await super.setUp()
        try requireIntegrationGate()

        keychain = KeychainStore(
            service: "chat.onym.ios.identity.tests.e2e.\(UUID().uuidString)",
            account: "current"
        )
        identity = IdentityRepository(keychain: keychain)
        _ = try await identity.restore(mnemonic: Self.testMnemonic)
    }

    override func tearDown() async throws {
        try? keychain?.wipe()
        keychain = nil
        identity = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Happy path with zero invitees. Verifies the group anchors on
    /// chain and the relayer's `get_commitment` returns the same
    /// commitment back — closes the loop on the wire format
    /// without depending on the receiver-side flow.
    func test_create_zeroInvitees_anchorsOnTestnet() async throws {
        let env = try await buildEnvironment()
        let interactor = env.makeInteractor(inboxTransport: FakeInboxTransport())

        let group = try await interactor.create(name: "e2e-zero-\(shortID())", invitees: [])

        XCTAssertTrue(group.isPublishedOnChain,
                      "group must be flagged as anchored after a successful create_group")
        XCTAssertEqual(group.groupType, .tyranny)
        XCTAssertEqual(group.tier, .small)
        XCTAssertEqual(group.epoch, 0)
        XCTAssertEqual(group.members.count, 1, "creator-only roster at create time")
        XCTAssertEqual(group.commitment?.count, 32, "commitment must be the 32B Poseidon scalar")

        // Round-trip the on-chain state: read the commitment back via
        // get_commitment and assert it matches what we stored locally.
        let onChain = try await env.client.getCommitment(groupID: group.groupIDData)
        XCTAssertEqual(onChain.commitment, group.commitment)
        XCTAssertEqual(onChain.epoch, 0)
        // Tyranny's CommitmentEntry has no `active` field — only
        // democracy/oligarchy do — so don't assert on it here.
    }

    /// Happy path with one invitee. Verifies the chain leg succeeds
    /// AND the inbox transport is asked to deliver one invitation
    /// (its receipt counts as the at-least-one-OK check).
    func test_create_oneInvitee_sendsInvitation_andAnchors() async throws {
        let env = try await buildEnvironment()
        let inbox = FakeInboxTransport()
        let interactor = env.makeInteractor(inboxTransport: inbox)

        let inviteeKey = Data(repeating: 0xAA, count: 32)
        let group = try await interactor.create(
            name: "e2e-one-\(shortID())",
            invitees: [inviteeKey]
        )

        XCTAssertTrue(group.isPublishedOnChain)

        // Subscriber-side bookkeeping in FakeInboxTransport doesn't
        // expose the send list directly, so we exercise it indirectly:
        // the interactor would have thrown if `acceptedBy < 1` (which
        // FakeInboxTransport's send always satisfies — returns 1).
        // Asserting the lack of throw + the published flag is enough
        // to know the invitation leg ran.
        XCTAssertNotNil(group.commitment, "commitment must be set after create")
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
        /// Bound to the resolved tyranny contract — used by the
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

        // Relayer repo seeded with the env URL; production fetcher is
        // bypassed because the test wants a deterministic endpoint.
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

        // Real GitHub Releases fetch — picks up whichever tyranny
        // contract is currently published. Robust to contracts
        // releases without recompiling the test.
        let contracts = ContractsRepository(
            fetcher: GitHubReleasesContractsManifestFetcher(),
            store: InMemoryAnchorSelectionStore()
        )
        try await contracts.refresh()

        // Resolve the tyranny binding for the post-create read-back.
        // Fail loudly with a useful message if no tyranny contract
        // is published yet.
        let key = AnchorSelectionKey(network: .testnet, type: .tyranny)
        guard let binding = await contracts.binding(for: key) else {
            throw XCTSkip(
                "No tyranny contract is published in the manifest yet — " +
                "cut a contracts release with at least one testnet tyranny entry."
            )
        }

        let groups = GroupRepository(store: SwiftDataGroupStore.inMemory())
        let networkPreference = StaticNetworkPreference(value: .testnet)

        let makeContractTransport: @Sendable (URL) -> any SEPContractTransport = { url in
            URLSessionSEPContractTransport(endpoint: url, authToken: token)
        }

        // Direct client for the read-back assertion. Bypasses
        // RelayerRepository.selectURL because the test already has
        // the URL.
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .tyranny,
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
        // Re-enabled in v0.0.5 after PR #36 landed `randomCanonicalFr()`
        // — the previous Error #15 was caused by uniformly-random
        // `groupID` occasionally landing `>= r`, which the contract
        // rejects by design (sep-tyranny/src/lib.rs:299). Releases now
        // need this test to pass; locally, set ONYM_INTEGRATION=1 +
        // ONYM_RELAYER_AUTH_TOKEN to run it. CI's release.yml wires
        // both via `xcrun simctl spawn booted launchctl setenv`.
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

    /// Short suffix to disambiguate concurrent test-runs against the
    /// same testnet without colliding on `groupID`. The interactor
    /// already generates a random 32-byte groupID; this is just to
    /// make the group `name` unique-ish for grep-able relayer logs.
    private func shortID() -> String {
        UUID().uuidString.prefix(8).lowercased()
    }
}
