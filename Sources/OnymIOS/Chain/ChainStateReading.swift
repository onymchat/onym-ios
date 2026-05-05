import Foundation

/// Narrow seam over `SEPContractClient.getCommitment(...)` used by
/// the receive-side dispatcher to verify that an inbound payload's
/// claimed `commitment` + `epoch` match what's actually anchored
/// on-chain. Mirrors the `InvitationEnvelopeDecrypting` /
/// `IdentitiesProviding` pattern: tests substitute a canned reader
/// without standing up the real chain transport.
///
/// V1 is Tyranny-only — that's where the admin-anchored update
/// flow exists. Non-Tyranny groups (`Anarchy` / `OneOnOne`) skip
/// chain verification entirely (they have no admin-driven update
/// path), so the seam doesn't expose a per-type method.
protocol ChainStateReading: Sendable {
    /// Fetch the current on-chain `(commitment, epoch)` for a Tyranny
    /// group. Throws on transport / decode failures or when the
    /// active relayer / Tyranny contract isn't configured. Receivers
    /// treat any throw as "couldn't verify, reject" — never as
    /// "verification passed".
    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry
}

/// Production conformer. Resolves the user's selected chain relayer
/// + Tyranny contract on every call (no caching — chain state is
/// the source of truth, and our SEP-relayer reads are cheap HTTPS
/// roundtrips at app-relevant scale). When the receiver doesn't
/// have a relayer or contract configured, the read throws — at the
/// dispatch layer that surfaces as "verification failed → reject the
/// payload", which is the safe default.
struct SEPContractChainStateReader: ChainStateReading {
    let relayers: RelayerRepository
    let contracts: ContractsRepository
    let networkPreference: any NetworkPreferenceProviding
    let makeContractTransport: @Sendable (URL) -> any SEPContractTransport

    init(
        relayers: RelayerRepository,
        contracts: ContractsRepository,
        networkPreference: any NetworkPreferenceProviding = UserDefaultsNetworkPreference(),
        makeContractTransport: @escaping @Sendable (URL) -> any SEPContractTransport = { url in
            URLSessionSEPContractTransport(
                endpoint: url,
                authToken: RelayerSecrets.authToken
            )
        }
    ) {
        self.relayers = relayers
        self.contracts = contracts
        self.networkPreference = networkPreference
        self.makeContractTransport = makeContractTransport
    }

    func tyrannyCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        guard let relayerURL = await relayers.selectURL() else {
            throw ChainReadError.noActiveRelayer
        }
        let activeNetwork = networkPreference.current()
        let key = AnchorSelectionKey(network: activeNetwork.contractNetwork, type: .tyranny)
        guard let binding = await contracts.binding(for: key) else {
            throw ChainReadError.noContractBinding
        }
        let transport = makeContractTransport(relayerURL)
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .tyranny,
            network: activeNetwork.sepNetwork,
            transport: transport
        )
        return try await client.getCommitment(groupID: groupID)
    }
}

enum ChainReadError: Error, Equatable, Sendable {
    case noActiveRelayer
    case noContractBinding
}
