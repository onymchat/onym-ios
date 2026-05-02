import CryptoKit
import Foundation
import Security

/// Stateless orchestration for the create-group flow. Holds dependencies
/// only — every call to `create` is independent. The view-model
/// (`CreateGroupFlow`) owns the form state and progress; this type only
/// knows how to drive a single end-to-end run.
///
/// ## Pipeline
///
/// 1. Validate name + invitees (caller already parsed hex → 32-byte
///    X25519 pubkeys).
/// 2. Resolve relayer URL (`RelayerRepository.selectURL`) +
///    contract binding (`ContractsRepository.binding(for: testnet/tyranny)`).
/// 3. Generate fresh `groupID` + `groupSecret` + `salt` (32 random
///    bytes each).
/// 4. Build the creator's `GovernanceMember` from the device's BLS
///    secret (single-member roster at creation; future invitees join
///    later via `update_commitment`).
/// 5. Generate the Tyranny PLONK proof via `GroupProofGenerator`.
/// 6. POST `create_group_v2` to the relayer; require
///    `accepted == true`.
/// 7. Insert the group locally via `GroupRepository.insert` then
///    `markPublished` so a subscriber sees `isPublishedOnChain = true`
///    immediately.
/// 8. For each invitee: encode + seal the `GroupInvitationPayload`,
///    send via `InboxTransport.send`, require `acceptedBy >= 1`. The
///    group is already saved on disk at this point — invitation
///    failures throw `CreateGroupError.invitationSendFailed` but
///    leave the group durable so a future "retry invites" UI can
///    pick it up.
struct CreateGroupInteractor: Sendable {
    let identity: IdentityRepository
    let relayers: RelayerRepository
    let contracts: ContractsRepository
    let groups: GroupRepository
    let networkPreference: any NetworkPreferenceProviding
    let proofGenerator: any GroupProofGenerator
    let inboxTransport: any InboxTransport
    /// Builds a `SEPContractTransport` from the relayer URL chosen
    /// per-call. Injected so tests can swap in a fake without
    /// touching `URLSession`.
    let makeContractTransport: @Sendable (URL) -> any SEPContractTransport

    init(
        identity: IdentityRepository,
        relayers: RelayerRepository,
        contracts: ContractsRepository,
        groups: GroupRepository,
        networkPreference: any NetworkPreferenceProviding = UserDefaultsNetworkPreference(),
        proofGenerator: any GroupProofGenerator = OnymGroupProofGenerator(),
        inboxTransport: any InboxTransport,
        makeContractTransport: @escaping @Sendable (URL) -> any SEPContractTransport = { url in
            URLSessionSEPContractTransport(endpoint: url)
        }
    ) {
        self.identity = identity
        self.relayers = relayers
        self.contracts = contracts
        self.groups = groups
        self.networkPreference = networkPreference
        self.proofGenerator = proofGenerator
        self.inboxTransport = inboxTransport
        self.makeContractTransport = makeContractTransport
    }

    /// Run the full pipeline. `onProgress` is called on the actor's
    /// executor — pass `{ progress in Task { @MainActor in … } }` if
    /// you need to update SwiftUI state from it.
    func create(
        name: String,
        invitees: [Data],
        onProgress: @Sendable (CreateGroupProgress) -> Void = { _ in }
    ) async throws -> ChatGroup {
        // 1. Validate
        onProgress(.validating)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CreateGroupError.invalidName
        }
        for (index, key) in invitees.enumerated() {
            guard key.count == 32 else {
                throw CreateGroupError.invalidInviteeKey(index: index)
            }
        }

        // 2. Resolve relayer + contract for the user's preferred network.
        guard let relayerURL = await relayers.selectURL() else {
            throw CreateGroupError.noActiveRelayer
        }
        let activeNetwork = networkPreference.current()
        let key = AnchorSelectionKey(network: activeNetwork.contractNetwork, type: .tyranny)
        guard let binding = await contracts.binding(for: key) else {
            throw CreateGroupError.noContractBinding(.tyranny)
        }

        // 3. Group params
        let groupID = Self.randomBytes(32)
        let groupSecret = Self.randomBytes(32)
        let salt = GroupCommitmentBuilder.generateSalt()
        let tier: SEPTier = .small

        // 4. Creator member (BLS pubkey + Poseidon leaf hash).
        let blsSecret: Data
        do {
            blsSecret = try await identity.blsSecretKey()
        } catch {
            throw CreateGroupError.missingIdentity
        }
        guard let identitySnapshot = await identity.currentIdentity() else {
            throw CreateGroupError.missingIdentity
        }
        let creatorMember: GovernanceMember
        do {
            creatorMember = GovernanceMember(
                publicKeyCompressed: identitySnapshot.blsPublicKey,
                leafHash: try GroupCommitmentBuilder.computeLeafHash(secretKey: blsSecret)
            )
        } catch {
            throw CreateGroupError.sdkFailure(String(describing: error))
        }
        let members = [creatorMember]  // already sorted (single-element list)

        // 5. Generate proof
        onProgress(.proving)
        let input = GroupProofCreateInput(
            groupType: .tyranny,
            tier: tier,
            members: members,
            adminBlsSecretKey: blsSecret,
            adminIndex: 0,
            groupID: groupID,
            salt: salt
        )
        let proof: GroupCreateProof
        do {
            proof = try proofGenerator.proveCreate(input)
        } catch let err as GroupProofGeneratorError {
            throw CreateGroupError.proofGenerationFailed(err)
        } catch {
            throw CreateGroupError.sdkFailure(String(describing: error))
        }

        // 6. Anchor on chain
        onProgress(.anchoring)
        let transport = makeContractTransport(relayerURL)
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .tyranny,
            network: activeNetwork.sepNetwork,
            transport: transport
        )
        let payload = TyrannyCreateGroupPayload(
            groupID: groupID,
            commitment: proof.commitment,
            tier: tier.rawValue,
            adminPubkeyCommitment: proof.adminPubkeyCommitment,
            proof: proof.proof,
            publicInputs: proof.publicInputs
        )
        let response: SEPSubmissionResponse
        do {
            response = try await client.createGroupTyranny(payload)
        } catch {
            throw CreateGroupError.anchorTransport(String(describing: error))
        }
        guard response.accepted else {
            throw CreateGroupError.anchorRejected(message: response.message)
        }

        // 7. Save locally
        let groupIDHex = groupID.map { String(format: "%02x", $0) }.joined()
        let adminPubkeyHex = identitySnapshot.blsPublicKey
            .map { String(format: "%02x", $0) }.joined()
        let group = ChatGroup(
            id: groupIDHex,
            name: trimmedName,
            groupSecret: groupSecret,
            createdAt: Date(),
            members: members,
            epoch: 0,
            salt: salt,
            commitment: proof.commitment,
            tier: tier,
            groupType: .tyranny,
            adminPubkeyHex: adminPubkeyHex,
            isPublishedOnChain: false
        )
        _ = await groups.insert(group)
        await groups.markPublished(id: group.id, commitment: proof.commitment)

        // 8. Send invitations
        if !invitees.isEmpty {
            onProgress(.sendingInvitations(total: invitees.count))
            let invitePayload = GroupInvitationPayload(
                version: 1,
                groupID: groupID,
                groupSecret: groupSecret,
                name: trimmedName,
                members: members,
                epoch: 0,
                salt: salt,
                commitment: proof.commitment,
                tierRaw: tier.rawValue,
                groupTypeRaw: SEPGroupType.tyranny.rawValue,
                adminPubkeyHex: adminPubkeyHex
            )
            let payloadBytes: Data
            do {
                payloadBytes = try JSONEncoder().encode(invitePayload)
            } catch {
                throw CreateGroupError.invitationEncodingFailed
            }
            for (index, inboxKey) in invitees.enumerated() {
                let sealed: Data
                do {
                    sealed = try await identity.sealInvitation(
                        payload: payloadBytes,
                        to: inboxKey
                    )
                } catch {
                    throw CreateGroupError.invitationSendFailed(
                        index: index,
                        reason: String(describing: error)
                    )
                }
                let inboxTag = Self.inboxTag(from: inboxKey)
                let receipt: PublishReceipt
                do {
                    receipt = try await inboxTransport.send(
                        sealed,
                        to: TransportInboxID(rawValue: inboxTag)
                    )
                } catch {
                    throw CreateGroupError.invitationSendFailed(
                        index: index,
                        reason: String(describing: error)
                    )
                }
                guard receipt.acceptedBy >= 1 else {
                    throw CreateGroupError.invitationSendFailed(
                        index: index,
                        reason: "no relay accepted the invitation"
                    )
                }
            }
        }

        // The flag was already flipped via `markPublished`; reload our
        // in-memory snapshot to mirror the on-disk state.
        return await groups.snapshots.first(where: { $0.contains { $0.id == group.id } })?
            .first { $0.id == group.id }
            ?? group
    }

    // MARK: - Helpers

    /// Same derivation as `IdentityRepository.inboxTag(from:)` —
    /// duplicated here because the repo's helper is private and we
    /// only need the formula, not the keychain lookup.
    private static func inboxTag(from inboxPublicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("sep-inbox-v1".utf8))
        hasher.update(data: inboxPublicKey)
        let hash = hasher.finalize()
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

enum CreateGroupProgress: Equatable, Sendable {
    case validating
    case proving
    case anchoring
    case sendingInvitations(total: Int)
}

enum CreateGroupError: Error, Equatable, Sendable {
    case invalidName
    case invalidInviteeKey(index: Int)
    case missingIdentity
    case noActiveRelayer
    case noContractBinding(GovernanceType)
    case proofGenerationFailed(GroupProofGeneratorError)
    case anchorTransport(String)
    case anchorRejected(message: String?)
    case invitationEncodingFailed
    case invitationSendFailed(index: Int, reason: String)
    case sdkFailure(String)
}

extension CreateGroupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidName: return "Group name cannot be empty"
        case let .invalidInviteeKey(index):
            return "Invitee #\(index + 1) is not a 32-byte X25519 public key"
        case .missingIdentity: return "No identity is loaded — bootstrap or restore first"
        case .noActiveRelayer: return "No relayer is configured"
        case let .noContractBinding(type):
            return "No \(type.rawValue) contract is published yet — pick one in Settings → Anchors"
        case let .proofGenerationFailed(err):
            return err.localizedDescription
        case let .anchorTransport(message):
            return "Couldn't reach the relayer: \(message)"
        case let .anchorRejected(message):
            return "Relayer rejected the create: \(message ?? "(no message)")"
        case .invitationEncodingFailed:
            return "Couldn't encode the invitation payload"
        case let .invitationSendFailed(index, reason):
            return "Invitation #\(index + 1) failed: \(reason)"
        case let .sdkFailure(message):
            return "SDK failure: \(message)"
        }
    }
}

extension GroupProofGeneratorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notYetSupported(type):
            return "\(type) is not supported yet — only Tyranny ships in this release"
        case let .adminIndexOutOfRange(index, count):
            return "Admin index \(index) is out of range for \(count) members"
        case let .sdkFailure(message):
            return "Proof generation failed: \(message)"
        }
    }
}
