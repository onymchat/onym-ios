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
            URLSessionSEPContractTransport(
                endpoint: url,
                authToken: RelayerSecrets.authToken
            )
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
    ///
    /// `governanceType` selects the contract family. Only `.tyranny`
    /// and `.oneOnOne` are wired today; the rest throw
    /// `CreateGroupError.unsupportedGovernanceType` early so the UI
    /// surfaces a clear "TBD" rather than a vague proof failure.
    ///
    /// `.oneOnOne` requires exactly **one** invitee — the peer. The
    /// creator mints a fresh ephemeral BLS Fr scalar for that peer
    /// (the founding ceremony has both keys present by SDK design)
    /// and ships it inside the invitation envelope so the receiver
    /// can adopt it as their per-dialog identity.
    func create(
        governanceType: SEPGroupType = .tyranny,
        name: String,
        invitees: [Data],
        onProgress: @Sendable (CreateGroupProgress) -> Void = { _ in }
    ) async throws -> ChatGroup {
        switch governanceType {
        case .tyranny:
            return try await createTyranny(name: name, invitees: invitees, onProgress: onProgress)
        case .oneOnOne:
            return try await createOneOnOne(name: name, invitees: invitees, onProgress: onProgress)
        case .anarchy:
            return try await createAnarchy(name: name, invitees: invitees, onProgress: onProgress)
        case .democracy, .oligarchy:
            throw CreateGroupError.unsupportedGovernanceType(governanceType)
        }
    }

    // MARK: - Tyranny

    private func createTyranny(
        name: String,
        invitees: [Data],
        onProgress: @Sendable (CreateGroupProgress) -> Void
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
        // `groupID` MUST be a canonical bls12-381 Fr (BE value < r) —
        // sep-tyranny's `is_canonical_fr(&group_id)` rejects anything
        // else with `Error::InvalidCommitmentEncoding` (#15). The check
        // exists to close a same-`group_id_fr` collision via
        // `group_id + p (mod 2^256)` — see the contract comment at
        // sep-tyranny/src/lib.rs:290–298.
        let groupID = Self.randomCanonicalFr()
        let groupSecret = Self.randomBytes(32)
        let salt = GroupCommitmentBuilder.generateSalt()
        let tier: SEPTier = .small

        // 4. Creator member (BLS pubkey + Poseidon leaf hash).
        let blsSecret: Data
        do {
            // Proof witness for `Tyranny.proveCreate(adminSecretKey:)` +
            // `Common.leafHash(secretKey:)`. The SDK takes the BLS
            // secret directly; no encapsulated equivalent. Stays in
            // this stack frame and is dropped when the function returns.
            // onym:allow-secret-read
            blsSecret = try await identity.blsSecretKey()
        } catch {
            throw CreateGroupError.missingIdentity
        }
        guard let identitySnapshot = await identity.currentIdentity() else {
            throw CreateGroupError.missingIdentity
        }
        guard let ownerID = await identity.currentSelectedID() else {
            // currentIdentity() returned non-nil but currentSelectedID()
            // returned nil — actor invariant violated, treat as missing.
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
        let creatorProfiles = await Self.creatorProfiles(
            from: identitySnapshot,
            identity: identity
        )
        let group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: ownerID,
            name: trimmedName,
            groupSecret: groupSecret,
            createdAt: Date(),
            members: members,
            memberProfiles: creatorProfiles,
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
            try await sendInvitations(invitePayload, to: invitees)
        }

        return await reloadGroup(group)
    }

    // MARK: - OneOnOne

    private func createOneOnOne(
        name: String,
        invitees: [Data],
        onProgress: @Sendable (CreateGroupProgress) -> Void
    ) async throws -> ChatGroup {
        // 1. Validate — 1-on-1 is exactly two parties: the creator and
        //    one peer. Zero or 2+ invitees is a programmer/UI error.
        onProgress(.validating)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CreateGroupError.invalidName
        }
        guard invitees.count == 1 else {
            throw CreateGroupError.oneOnOneRequiresExactlyOnePeer(got: invitees.count)
        }
        let peerInboxKey = invitees[0]
        guard peerInboxKey.count == 32 else {
            throw CreateGroupError.invalidInviteeKey(index: 0)
        }

        // 2. Resolve relayer + contract.
        guard let relayerURL = await relayers.selectURL() else {
            throw CreateGroupError.noActiveRelayer
        }
        let activeNetwork = networkPreference.current()
        let key = AnchorSelectionKey(network: activeNetwork.contractNetwork, type: .oneonone)
        guard let binding = await contracts.binding(for: key) else {
            throw CreateGroupError.noContractBinding(.oneonone)
        }

        // 3. Group params (no tier — OneOnOne contract is fixed depth).
        // sep-oneonone doesn't gate `group_id` canonicality today (no
        // proof binding), but we use the canonical sampler anyway for
        // consistency with Tyranny + to keep all on-chain group IDs
        // valid Fr scalars in case a future contract rev adds the check.
        let groupID = Self.randomCanonicalFr()
        let groupSecret = Self.randomBytes(32)
        let salt = GroupCommitmentBuilder.generateSalt()

        // 4. Both BLS secrets must be present at create time — the SDK's
        //    founding ceremony is the one moment both keys exist on the
        //    same device. The peer secret is shipped inside the
        //    invitation envelope so the receiver adopts it as their
        //    per-dialog identity.
        let creatorBlsSecret: Data
        do {
            // Proof witness for `OneOnOne.proveCreate(secretKey0:)` +
            // `Common.leafHash(secretKey:)`. Same justification as the
            // Tyranny path — SDK takes the BLS secret directly. Stays
            // in this stack frame.
            // onym:allow-secret-read
            creatorBlsSecret = try await identity.blsSecretKey()
        } catch {
            throw CreateGroupError.missingIdentity
        }
        guard let identitySnapshot = await identity.currentIdentity() else {
            throw CreateGroupError.missingIdentity
        }
        guard let ownerID = await identity.currentSelectedID() else {
            throw CreateGroupError.missingIdentity
        }
        // BLS secret keys are canonical Fr by convention. The SDK reduces
        // silently if not, but any future strictness check would silently
        // break us — so generate canonical at the source.
        var peerBlsSecret = Self.randomCanonicalFr()
        // The OneOnOne SDK rejects equal secrets. Vanishingly unlikely
        // with 256 bits of entropy, but cheap to defend against —
        // resample on the off chance of a collision.
        while peerBlsSecret == creatorBlsSecret {
            peerBlsSecret = Self.randomCanonicalFr()
        }

        let creatorMember: GovernanceMember
        let peerMember: GovernanceMember
        do {
            creatorMember = GovernanceMember(
                publicKeyCompressed: identitySnapshot.blsPublicKey,
                leafHash: try GroupCommitmentBuilder.computeLeafHash(secretKey: creatorBlsSecret)
            )
            peerMember = GovernanceMember(
                publicKeyCompressed: try GroupCommitmentBuilder.computePublicKey(secretKey: peerBlsSecret),
                leafHash: try GroupCommitmentBuilder.computeLeafHash(secretKey: peerBlsSecret)
            )
        } catch {
            throw CreateGroupError.sdkFailure(String(describing: error))
        }
        let members = [creatorMember, peerMember].sorted { lhs, rhs in
            lhs.publicKeyCompressed.lexicographicallyPrecedes(rhs.publicKeyCompressed)
        }

        // 5. Generate proof — OneOnOne SDK takes both secrets directly.
        onProgress(.proving)
        let proofInput = GroupProofCreateInput(
            groupType: .oneOnOne,
            tier: .small,                   // ignored by SDK
            members: members,               // ignored by SDK
            adminBlsSecretKey: creatorBlsSecret,
            adminIndex: 0,                  // ignored by SDK
            groupID: groupID,
            salt: salt,
            peerBlsSecretKey: peerBlsSecret
        )
        let proof: GroupCreateProof
        do {
            proof = try proofGenerator.proveCreate(proofInput)
        } catch let err as GroupProofGeneratorError {
            throw CreateGroupError.proofGenerationFailed(err)
        } catch {
            throw CreateGroupError.sdkFailure(String(describing: error))
        }

        // 6. Anchor on chain.
        onProgress(.anchoring)
        let transport = makeContractTransport(relayerURL)
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .oneOnOne,
            network: activeNetwork.sepNetwork,
            transport: transport
        )
        let payload = OneOnOneCreateGroupPayload(
            groupID: groupID,
            commitment: proof.commitment,
            proof: proof.proof,
            publicInputs: proof.publicInputs
        )
        let response: SEPSubmissionResponse
        do {
            response = try await client.createGroupOneOnOne(payload)
        } catch {
            throw CreateGroupError.anchorTransport(String(describing: error))
        }
        guard response.accepted else {
            throw CreateGroupError.anchorRejected(message: response.message)
        }

        // 7. Save locally — no admin in 1-on-1, so adminPubkeyHex stays nil.
        let groupIDHex = groupID.map { String(format: "%02x", $0) }.joined()
        let creatorProfiles = await Self.creatorProfiles(
            from: identitySnapshot,
            identity: identity
        )
        let group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: ownerID,
            name: trimmedName,
            groupSecret: groupSecret,
            createdAt: Date(),
            members: members,
            memberProfiles: creatorProfiles,
            epoch: 0,
            salt: salt,
            commitment: proof.commitment,
            tier: .small,
            groupType: .oneOnOne,
            adminPubkeyHex: nil,
            isPublishedOnChain: false
        )
        _ = await groups.insert(group)
        await groups.markPublished(id: group.id, commitment: proof.commitment)

        // 8. Send the single invitation — peer secret rides inside.
        onProgress(.sendingInvitations(total: 1))
        let invitePayload = GroupInvitationPayload(
            version: 1,
            groupID: groupID,
            groupSecret: groupSecret,
            name: trimmedName,
            members: members,
            epoch: 0,
            salt: salt,
            commitment: proof.commitment,
            tierRaw: SEPTier.small.rawValue,
            groupTypeRaw: SEPGroupType.oneOnOne.rawValue,
            adminPubkeyHex: nil,
            peerBlsSecret: peerBlsSecret
        )
        try await sendInvitations(invitePayload, to: [peerInboxKey])

        return await reloadGroup(group)
    }

    // MARK: - Anarchy

    /// Anarchy create: founding ceremony is a membership proof at
    /// epoch 0 over a single-member roster (just the creator). No
    /// admin field, no peer secret. The roster grows later via
    /// `update_commitment` (post-V1 scope) — for now any invitees the
    /// user pastes get the standard sealed invitation envelope so they
    /// can join via that future flow.
    ///
    /// Mirrors `createTyranny`'s shape (tier-bounded depth + per-call
    /// canonical-Fr groupID + invitation send loop) but uses
    /// `AnarchyCreateGroupPayload` (no `admin_pubkey_commitment`, adds
    /// `member_count`) and saves the group with `groupType: .anarchy,
    /// adminPubkeyHex: nil`.
    private func createAnarchy(
        name: String,
        invitees: [Data],
        onProgress: @Sendable (CreateGroupProgress) -> Void
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

        // 2. Resolve relayer + contract.
        guard let relayerURL = await relayers.selectURL() else {
            throw CreateGroupError.noActiveRelayer
        }
        let activeNetwork = networkPreference.current()
        let key = AnchorSelectionKey(network: activeNetwork.contractNetwork, type: .anarchy)
        guard let binding = await contracts.binding(for: key) else {
            throw CreateGroupError.noContractBinding(.anarchy)
        }

        // 3. Group params. sep-anarchy doesn't gate `group_id`
        // canonicality today (no proof binding), but use the canonical
        // sampler anyway for consistency with Tyranny / OneOnOne.
        let groupID = Self.randomCanonicalFr()
        let groupSecret = Self.randomBytes(32)
        let salt = GroupCommitmentBuilder.generateSalt()
        let tier: SEPTier = .small

        // 4. Creator member.
        let blsSecret: Data
        do {
            // Proof witness for `Anarchy.proveMembership(proverSecretKey:)` +
            // `Common.leafHash(secretKey:)`. Same justification as the
            // Tyranny / OneOnOne paths.
            // onym:allow-secret-read
            blsSecret = try await identity.blsSecretKey()
        } catch {
            throw CreateGroupError.missingIdentity
        }
        guard let identitySnapshot = await identity.currentIdentity() else {
            throw CreateGroupError.missingIdentity
        }
        guard let ownerID = await identity.currentSelectedID() else {
            // currentIdentity() returned non-nil but currentSelectedID()
            // returned nil — actor invariant violated, treat as missing.
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
        let members = [creatorMember]  // single-element list, already sorted

        // 5. Generate proof — Anarchy.proveMembership at epoch 0.
        onProgress(.proving)
        let proofInput = GroupProofCreateInput(
            groupType: .anarchy,
            tier: tier,
            members: members,
            adminBlsSecretKey: blsSecret,    // re-used as `proverSecretKey`
            adminIndex: 0,                    // creator's leaf position
            groupID: groupID,                 // not bound into proof for Anarchy
            salt: salt
        )
        let proof: GroupCreateProof
        do {
            proof = try proofGenerator.proveCreate(proofInput)
        } catch let err as GroupProofGeneratorError {
            throw CreateGroupError.proofGenerationFailed(err)
        } catch {
            throw CreateGroupError.sdkFailure(String(describing: error))
        }

        // 6. Anchor on chain.
        onProgress(.anchoring)
        let transport = makeContractTransport(relayerURL)
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .anarchy,
            network: activeNetwork.sepNetwork,
            transport: transport
        )
        // `member_count` is informational and the contract accepts `0`
        // as the documented "not tracked" sentinel (per `sep-anarchy`'s
        // `create_group` doc — "Operators who don't want to publish a
        // count pass `0`"). Pass the sentinel so chain observers see
        // only the tier, not the exact roster size at create time.
        // The accurate count lives in the local model.
        let payload = AnarchyCreateGroupPayload(
            groupID: groupID,
            commitment: proof.commitment,
            tier: tier.rawValue,
            memberCount: 0,
            proof: proof.proof,
            publicInputs: proof.publicInputs
        )
        let response: SEPSubmissionResponse
        do {
            response = try await client.createGroupAnarchy(payload)
        } catch {
            throw CreateGroupError.anchorTransport(String(describing: error))
        }
        guard response.accepted else {
            throw CreateGroupError.anchorRejected(message: response.message)
        }

        // 7. Save locally — no admin in Anarchy, so adminPubkeyHex stays nil.
        let groupIDHex = groupID.map { String(format: "%02x", $0) }.joined()
        let creatorProfiles = await Self.creatorProfiles(
            from: identitySnapshot,
            identity: identity
        )
        let group = ChatGroup(
            id: groupIDHex,
            ownerIdentityID: ownerID,
            name: trimmedName,
            groupSecret: groupSecret,
            createdAt: Date(),
            members: members,
            memberProfiles: creatorProfiles,
            epoch: 0,
            salt: salt,
            commitment: proof.commitment,
            tier: tier,
            groupType: .anarchy,
            adminPubkeyHex: nil,
            isPublishedOnChain: false
        )
        _ = await groups.insert(group)
        await groups.markPublished(id: group.id, commitment: proof.commitment)

        // 8. Send invitations (if any). Anarchy invitations carry no
        // admin field and no peer secret — the receiver uses their
        // own BLS identity when they later add themselves via
        // `update_commitment`.
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
                groupTypeRaw: SEPGroupType.anarchy.rawValue,
                adminPubkeyHex: nil
            )
            try await sendInvitations(invitePayload, to: invitees)
        }

        return await reloadGroup(group)
    }

    // MARK: - Shared invitation send loop

    private func sendInvitations(
        _ invitePayload: GroupInvitationPayload,
        to invitees: [Data]
    ) async throws {
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

    /// Reload the freshly-published group from the repo so the caller
    /// sees `isPublishedOnChain = true` (the flag was flipped via
    /// `markPublished`, but the local `group` snapshot was built
    /// before that mutation).
    private func reloadGroup(_ group: ChatGroup) async -> ChatGroup {
        await groups.snapshots.first(where: { $0.contains { $0.id == group.id } })?
            .first { $0.id == group.id }
            ?? group
    }

    // MARK: - Member profiles

    /// Build the single-entry `memberProfiles` map for a freshly-created
    /// group: just the creator, keyed by their lowercase BLS pubkey
    /// hex. Alias is read once at create time — a later identity
    /// rename doesn't backfill historical groups.
    ///
    /// Empty alias when the identity has no name resolved (very early
    /// post-bootstrap window). Renders as a blank label with the BLS
    /// fingerprint still visible — better than crashing or showing
    /// stale state.
    private static func creatorProfiles(
        from identitySnapshot: Identity,
        identity: IdentityRepository
    ) async -> [String: MemberProfile] {
        let alias = await identity.currentIdentityName() ?? ""
        let creatorBlsHex = identitySnapshot.blsPublicKey
            .map { String(format: "%02x", $0) }.joined()
        return [
            creatorBlsHex: MemberProfile(
                alias: alias,
                inboxPublicKey: identitySnapshot.inboxPublicKey
            )
        ]
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

    /// Uniformly-random 32-byte BE value strictly less than the
    /// bls12-381 scalar field order `r`. Rejection-samples until a
    /// canonical value falls out — accept rate is `r / 2^256 ≈ 0.453`,
    /// so the loop terminates in ~2.2 iterations on average.
    ///
    /// Why we can't just take `randomBytes(32) mod r`: the contract
    /// rejects any non-canonical encoding outright (sep-tyranny
    /// `Error::InvalidCommitmentEncoding`), and the SDK's silent mod-r
    /// reduction would diverge from the contract's check on ~25% of
    /// inputs. Generating canonically at the source removes the
    /// reduction question entirely.
    static func randomCanonicalFr() -> Data {
        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            if isCanonicalFr(bytes) {
                return Data(bytes)
            }
        }
    }

    /// True iff the 32-byte BE value is strictly less than the
    /// bls12-381 scalar field order
    /// `r = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001`.
    /// Mirrors the contract's `is_canonical_fr` predicate
    /// (sep-tyranny/src/lib.rs:688).
    static func isCanonicalFr(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 32 else { return false }
        let r: [UInt8] = [
            0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
            0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
            0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
        ]
        for i in 0..<32 {
            if bytes[i] < r[i] { return true }
            if bytes[i] > r[i] { return false }
        }
        return false  // bytes == r → not canonical (must be strictly less)
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
    /// `.oneOnOne` requires exactly one invitee (the peer); the UI
    /// gates this but the interactor double-checks.
    case oneOnOneRequiresExactlyOnePeer(got: Int)
    /// Caller passed `.anarchy` / `.democracy` / `.oligarchy` — not
    /// wired to the chain yet.
    case unsupportedGovernanceType(SEPGroupType)
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
        case let .oneOnOneRequiresExactlyOnePeer(got):
            return "1-on-1 dialog needs exactly 1 peer (got \(got))"
        case let .unsupportedGovernanceType(type):
            return "\(type.rawValue) is not supported yet"
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
        case .missingPeerSecret:
            return "1-on-1 dialog is missing the peer's BLS secret"
        case let .sdkFailure(message):
            return "Proof generation failed: \(message)"
        }
    }
}
