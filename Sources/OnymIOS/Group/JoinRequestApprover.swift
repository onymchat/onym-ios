import CryptoKit
import Foundation

/// Test seam used by `ApproveRequestsFlow`. The production conformer
/// is `JoinRequestApprover` itself; tests inject a stub instead of
/// standing up the full keychain + transport stack just to exercise
/// the flow's bookkeeping.
protocol JoinRequestApproving: Sendable {
    var pending: AsyncStream<[JoinRequestApprover.PendingRequest]> { get }
    func start() async
    func approve(requestId: String) async -> JoinRequestApprover.ApproveOutcome
    func decline(requestId: String) async
}

/// Sender-side: turn raw `IntroRequest`s into UI-renderable
/// pending requests, and on user approval ship the actual sealed
/// `GroupInvitationPayload` to the joiner.
///
/// Lifecycle:
///  1. `start` subscribes to `IntroRequestStore.requests` and
///     decrypts each newly-arrived envelope using the matching
///     `IntroKeyEntry.introPrivateKey` from `IntroKeyStore`. Decrypt
///     failures bump `decryptFailureCount` (drives a future
///     diagnostic surface; users never see them).
///  2. UI subscribes to `pending` and renders "X wants to join Y.
///     Approve?" prompts.
///  3. On Approve → seals the existing `GroupInvitationPayload`
///     (built from the local `ChatGroup`) to the joiner's identity
///     inbox key, ships via `inboxTransport.send`, revokes the
///     intro key. The pump from PR-3 stops listening on that intro
///     tag within one emission window.
///  4. On Decline → drop the request, revoke the intro key. No
///     NACK to the joiner; their JoinScreen times out gracefully.
actor JoinRequestApprover: JoinRequestApproving {

    /// UI-renderable view of one decrypted, awaiting-action request.
    struct PendingRequest: Equatable, Sendable, Identifiable {
        /// Stable id == `IntroRequest.id`. Approve / Decline use it
        /// as the dedupe key.
        let id: String
        let joinerInboxPublicKey: Data
        /// 48-byte BLS pubkey when the joiner sent it (current
        /// builds always do). `nil` when the request came from a
        /// pre-PR-4 client; the approver still ships the invitation
        /// back, but skips the local roster update because there's
        /// no stable cross-device key to record under.
        let joinerBlsPublicKey: Data?
        /// 32-byte Poseidon leaf hash. Required for Tyranny approve:
        /// the admin can't generate the on-chain `update_commitment`
        /// proof without it (it's the joiner's leaf in the new tree).
        /// `nil` when the joiner shipped a pre-PR-13 request — those
        /// requests can't be approved on-chain and surface as
        /// `.outdatedJoinerClient`.
        let joinerLeafHash: Data?
        /// 32-byte Ed25519 raw pubkey — joiner's
        /// `Identity.stellarPublicKey`. Plumbed through to the
        /// joiner's `MemberProfile` and the fan-out
        /// `MemberAnnouncementPayload` so existing members can
        /// verify the joiner's chat-message envelope signatures
        /// (PR 4).
        let joinerSendingPublicKey: Data
        let joinerDisplayLabel: String
        let groupId: Data
        /// Looked up from the local `GroupRepository`. nil if the
        /// joiner is asking about a group we don't know — surface a
        /// "this invite isn't for any group on this device" error
        /// in the UI rather than approving.
        let groupName: String?
    }

    enum ApproveOutcome: Equatable, Sendable {
        case sent
        case unknownGroup
        case unknownRequest
        case noIdentityLoaded
        case transportFailed(String)
        /// Joiner shipped a pre-PR-13 request without `joiner_leaf_hash`.
        /// Admin can't extend the on-chain tree without it; user must
        /// ask the joiner to upgrade their client.
        case outdatedJoinerClient
        /// `RelayerRepository.selectURL()` returned nil — the user has
        /// no chain relayer configured. Different from the Nostr-relays
        /// path; admin-anchoring needs the HTTPS contract relayer.
        case noActiveRelayer
        /// `ContractsRepository.binding(for:)` returned nil — the
        /// user hasn't picked a deployed Tyranny contract for the
        /// active network in Settings → Anchors.
        case noContractBinding
        /// The active identity isn't this group's admin: the BLS
        /// pubkey derived from the keychain's secret doesn't match
        /// the admin pubkey baked into the local group state. Most
        /// common cause: user switched to a different identity
        /// between group create-time and approve-time, or restored
        /// from a different recovery phrase. Catches cleanly what
        /// would otherwise surface as a cryptic SDK proof failure.
        case notAdminOfThisGroup
        /// `Tyranny.proveUpdate` failed — usually means a corrupted
        /// roster, wrong tier depth, or SDK FFI error. Diagnostic
        /// detail in the associated string.
        case proofFailed(String)
        /// Relayer accepted the POST but the contract rejected the
        /// proof (admin pubkey mismatch, replay, etc.).
        case anchorRejected(String)
    }

    /// Outcome of `removeMember`. Mirrors `GroupMemberRemover.Outcome`
    /// from onym-android.
    enum RemoveOutcome: Equatable, Sendable {
        /// Anchored on chain, persisted locally, fanned out (best-effort).
        case sent
        /// No group with this id under the active identity.
        case unknownGroup
        /// No identity selected.
        case noIdentityLoaded
        /// Removal only exists for Tyranny groups.
        case notTyrannyGroup
        /// Active identity isn't this group's admin.
        case notAdminOfThisGroup
        /// The admin can't remove themself.
        case cannotRemoveSelf
        /// BLS hex not present in `ChatGroup.memberProfiles`.
        case unknownMember
        /// The member's profile is already tombstoned.
        case alreadyRemoved
        /// Present in the app-level directory but missing from the
        /// on-chain `ChatGroup.members` roster — the tree can't be
        /// shrunk around a leaf that was never in it. (Directory and
        /// roster are allowed to diverge; removal is the first flow
        /// that needs them to agree.)
        case memberNotInRoster
        /// `RelayerRepository.selectURL()` returned nil.
        case noActiveRelayer
        /// No deployed Tyranny contract for the active network.
        case noContractBinding
        /// `Tyranny.proveUpdate` failed.
        case proofFailed(String)
        /// Relayer accepted the POST but the contract rejected.
        case anchorRejected(String)
        /// Local/transport failure outside the prove+anchor leg.
        case transportFailed(String)
    }

    private let identity: IdentityRepository
    private let introKeyStore: any IntroKeyStore
    private let introRequestStore: any IntroRequestStore
    private let groupRepository: GroupRepository
    private let inboxTransport: any InboxTransport
    private let relayers: RelayerRepository
    private let contracts: ContractsRepository
    private let networkPreference: any NetworkPreferenceProviding
    private let proofGenerator: any GroupProofGenerator
    private let makeContractTransport: @Sendable (URL) -> any SEPContractTransport

    private var pendingValue: [PendingRequest] = []
    private var pendingContinuations: [UUID: AsyncStream<[PendingRequest]>.Continuation] = [:]
    private var decryptFailures: Int = 0
    private var collectorTask: Task<Void, Never>?
    /// Serializes `approve` AND `removeMember` calls. Each one reads
    /// `group.epoch`, proves an `update_commitment` from it, submits,
    /// then persists `epoch + 1`. The actor re-enters at the
    /// multi-second prove / submit awaits, so two overlapping
    /// mutations would both read the same stale epoch — the chain
    /// accepts the first and rejects the second as a stale-epoch
    /// replay (the loser silently fails). Chaining each operation onto
    /// the previous one's completion guarantees the
    /// read-prove-submit-persist critical section runs to completion
    /// before the next begins. Type-erased to `Void` so approvals and
    /// removals share one chain (they mutate the same group state).
    private var approvalChain: Task<Void, Never>?

    init(
        identity: IdentityRepository,
        introKeyStore: any IntroKeyStore,
        introRequestStore: any IntroRequestStore,
        groupRepository: GroupRepository,
        inboxTransport: any InboxTransport,
        relayers: RelayerRepository,
        contracts: ContractsRepository,
        networkPreference: any NetworkPreferenceProviding = UserDefaultsNetworkPreference(),
        proofGenerator: any GroupProofGenerator = OnymGroupProofGenerator(),
        makeContractTransport: @escaping @Sendable (URL) -> any SEPContractTransport = { url in
            URLSessionSEPContractTransport(
                endpoint: url,
                authToken: RelayerSecrets.authToken
            )
        }
    ) {
        self.identity = identity
        self.introKeyStore = introKeyStore
        self.introRequestStore = introRequestStore
        self.groupRepository = groupRepository
        self.inboxTransport = inboxTransport
        self.relayers = relayers
        self.contracts = contracts
        self.networkPreference = networkPreference
        self.proofGenerator = proofGenerator
        self.makeContractTransport = makeContractTransport
    }

    /// Hot stream of decoded pending requests. Replays the current
    /// snapshot to new subscribers; re-emits on every change.
    nonisolated var pending: AsyncStream<[PendingRequest]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribePending(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribePending(id: id) }
            }
        }
    }

    /// Diagnostic counter — bumped each time an envelope fails to
    /// decode (forged link campaign, corrupted intro key, etc.).
    /// Wired to a Settings → Diagnostics view in a follow-up.
    func decryptFailureCount() -> Int { decryptFailures }

    /// Subscribe to `IntroRequestStore.requests` and keep `pending`
    /// in sync. Idempotent — a second call replaces the prior
    /// collector. The collector runs until `stop` or actor deinit.
    func start() {
        collectorTask?.cancel()
        let store = introRequestStore
        collectorTask = Task { [weak self] in
            for await raw in store.requests {
                if Task.isCancelled { break }
                await self?.refresh(from: raw)
            }
        }
    }

    func stop() {
        collectorTask?.cancel()
        collectorTask = nil
    }

    /// Test seam — synchronously decode the current store snapshot
    /// and emit. Lets unit tests assert the decode path without
    /// fighting collector scheduling.
    func pumpOnce() async {
        let raw = await introRequestStore.current()
        await refresh(from: raw)
    }

    /// Public entry point. Serializes onto any in-flight approval /
    /// removal via `approvalChain` so each on-chain `update_commitment`
    /// reads the epoch the previous operation persisted, then defers to
    /// `performApprove` for the actual anchor flow.
    func approve(requestId: String) async -> ApproveOutcome {
        await enqueue { await self.performApprove(requestId: requestId) }
    }

    /// Remove `victimBlsHex` (lowercase 96-char BLS pubkey hex) from
    /// `groupIDHex`, with groupSecret rotation. Serialized through the
    /// same `approvalChain` as `approve` — both are
    /// read-prove-anchor-persist on the same group and must not
    /// interleave. See `performRemove` for the flow.
    func removeMember(groupIDHex: String, victimBlsHex: String) async -> RemoveOutcome {
        await enqueue {
            await self.performRemove(groupIDHex: groupIDHex, victimBlsHex: victimBlsHex)
        }
    }

    /// Chain `op` onto the previous group-mutating operation. The
    /// read-and-assign of `approvalChain` is synchronous (no `await`
    /// between), so overlapping callers chain deterministically.
    private func enqueue<T: Sendable>(
        _ op: @escaping @Sendable () async -> T
    ) async -> T {
        let previous = approvalChain
        let task = Task { () -> T in
            _ = await previous?.value
            return await op()
        }
        approvalChain = Task { _ = await task.value }
        return await task.value
    }

    /// Approve a pending request. Tyranny-only on-chain anchor flow:
    ///
    ///   1. Verify joiner shipped both `bls_pub` + `leaf_hash`.
    ///   2. Build new sorted member list = current ∪ joiner.
    ///   3. Compute new Poseidon root via `Common.merkleRoot`.
    ///   4. Mint a fresh `salt_new`.
    ///   5. Generate `Tyranny.proveUpdate` with admin's BLS secret.
    ///   6. POST `update_commitment` to the chain relayer.
    ///   7. Only on `accepted == true`: update local `ChatGroup`
    ///      (members, commitment, epoch, salt), seal + ship the
    ///      `GroupInvitationPayload` (with new state) to the joiner,
    ///      fanout `MemberAnnouncementPayload` (also with new state)
    ///      to existing members, revoke intro key + consume request.
    ///
    /// Failures at the proof / anchor steps return without mutating
    /// any local state or consuming the request, so the admin can
    /// retry. Failures at seal+ship after a successful anchor leave
    /// the on-chain state advanced but the joiner uninformed —
    /// out-of-band recovery is required (rare in practice).
    ///
    /// Non-Tyranny groups fall back to the pre-PR-13 ship-only flow
    /// (no chain anchor) because there's no admin-driven update path
    /// in `OneOnOne` / `Anarchy`. PR-13b's receiver verification
    /// gates announcements to Tyranny groups specifically; other
    /// types stay best-effort.
    private func performApprove(requestId: String) async -> ApproveOutcome {
        guard let req = pendingValue.first(where: { $0.id == requestId }) else {
            return .unknownRequest
        }
        guard let activeIdentity = await identity.currentIdentity() else {
            return .noIdentityLoaded
        }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.groupIDData == req.groupId }) else {
            return .unknownGroup
        }

        // PR-13a admin-anchor path is Tyranny-only. Other types fall
        // through to the pre-PR-13 ship-only flow at the bottom.
        var anchored = group
        if group.groupType == .tyranny {
            switch await anchorTyrannyJoin(
                req: req,
                group: group,
                activeIdentity: activeIdentity
            ) {
            case .failed(let outcome):
                return outcome
            case .ok(let updated):
                anchored = updated
                // Persist the advanced state immediately so a
                // subsequent crash before seal+ship doesn't lose the
                // chain transition.
                await groupRepository.insert(anchored)
            }
        }

        let invite = GroupInvitationPayload(
            version: 1,
            groupID: anchored.groupIDData,
            groupSecret: anchored.groupSecret,
            name: anchored.name,
            members: anchored.members,
            epoch: anchored.epoch,
            salt: anchored.salt,
            commitment: anchored.commitment,
            tierRaw: anchored.tier.rawValue,
            groupTypeRaw: anchored.groupType.rawValue,
            adminPubkeyHex: anchored.adminPubkeyHex,
            // Ship the directory-as-known so the joiner sees existing
            // peers + admin by name from the moment they land. The
            // joiner's own profile gets backfilled by the receiver's
            // materializer from their active identity.
            memberProfiles: anchored.memberProfiles.isEmpty ? nil : anchored.memberProfiles,
            // Tyranny invitees only get the full snapshot here (the
            // create-time offer carries nothing), so this is where the
            // group photo reaches them.
            avatar: anchored.avatarJPEG,
            // Carry the group's invitation/intro so it persists for the
            // joiner once they materialize the group.
            invitationMessage: anchored.invitationMessage
        )
        let payloadBytes: Data
        do {
            payloadBytes = try JSONEncoder().encode(invite)
        } catch {
            return .transportFailed("encode: \(error)")
        }
        let sealed: Data
        do {
            sealed = try await identity.sealInvitation(
                payload: payloadBytes,
                to: req.joinerInboxPublicKey
            )
        } catch {
            return .transportFailed("seal: \(error)")
        }
        let joinerTag = TransportInboxID(
            rawValue: IntroInboxPump.inboxTag(from: req.joinerInboxPublicKey)
        )
        let receipt: PublishReceipt
        do {
            receipt = try await inboxTransport.send(sealed, to: joinerTag)
        } catch {
            return .transportFailed("send: \(error)")
        }
        guard receipt.acceptedBy >= 1 else {
            return .transportFailed("no relay accepted the invitation")
        }
        // Record the joiner in the local group's view-facing roster
        // (alias / inbox-pub) so the admin sees their alias in the
        // UI. The cryptographic roster (`anchored.members`) was
        // already updated by the anchor step. Both side-effects only
        // run when the joiner shipped a BLS pubkey.
        if let blsPub = req.joinerBlsPublicKey {
            await recordJoiner(
                in: anchored,
                blsPub: blsPub,
                inboxPub: req.joinerInboxPublicKey,
                sendingPub: req.joinerSendingPublicKey,
                alias: req.joinerDisplayLabel
            )
            await broadcastJoin(
                in: anchored,
                joinerBlsPub: blsPub,
                joinerInboxPub: req.joinerInboxPublicKey,
                joinerSendingPub: req.joinerSendingPublicKey,
                joinerAlias: req.joinerDisplayLabel
            )
        }
        // Best-effort cleanup.
        if let introPub = await findIntroPub(forRequestID: requestId) {
            await introKeyStore.revoke(introPublicKey: introPub)
        }
        await introRequestStore.consume(id: requestId)
        return .sent
    }

    /// Outcome shape for the anchor helper. `Result` is unergonomic
    /// here because `ApproveOutcome` doesn't conform to `Error`.
    private enum AnchorOutcome {
        case ok(ChatGroup)
        case failed(ApproveOutcome)
    }

    /// On-chain anchor leg of `approve` — Tyranny only. Returns the
    /// updated `ChatGroup` (post-anchor) on success, or an
    /// `ApproveOutcome` describing the failure on any short-circuit.
    /// Pure: never mutates local state. Caller persists.
    private func anchorTyrannyJoin(
        req: PendingRequest,
        group: ChatGroup,
        activeIdentity: Identity
    ) async -> AnchorOutcome {
        guard let joinerBlsPub = req.joinerBlsPublicKey,
              let joinerLeafHash = req.joinerLeafHash
        else {
            return .failed(.outdatedJoinerClient)
        }
        guard let adminPubkeyHex = group.adminPubkeyHex else {
            // Tyranny group without a stored admin pubkey shouldn't
            // exist (CreateGroupInteractor stamps it at create time).
            // Reject defensively.
            return .failed(.transportFailed("group missing adminPubkeyHex"))
        }
        guard let relayerURL = await relayers.selectURL() else {
            return .failed(.noActiveRelayer)
        }
        let activeNetwork = networkPreference.current()
        let key = AnchorSelectionKey(network: activeNetwork.contractNetwork, type: .tyranny)
        guard let binding = await contracts.binding(for: key) else {
            return .failed(.noContractBinding)
        }

        // Resolve admin's index in the OLD member roster.
        let adminBytes = ChatGroup.bytes(fromHex: adminPubkeyHex)
        guard let adminIndexOld = group.members.firstIndex(
            where: { $0.publicKeyCompressed == adminBytes }
        ) else {
            return .failed(.transportFailed("admin not in members roster"))
        }

        // Build new sorted member list including the joiner. Compute
        // the new Poseidon root over the new tree.
        let joinerMember = GovernanceMember(
            publicKeyCompressed: joinerBlsPub,
            leafHash: joinerLeafHash
        )
        let newMembers = (group.members + [joinerMember]).sorted { lhs, rhs in
            lhs.publicKeyCompressed.lexicographicallyPrecedes(rhs.publicKeyCompressed)
        }
        let memberRootNew: Data
        do {
            memberRootNew = try GroupCommitmentBuilder.computeMerkleRoot(
                members: newMembers,
                tier: group.tier
            )
        } catch {
            return .failed(.proofFailed("merkle_root: \(error)"))
        }
        let saltNew = GroupCommitmentBuilder.generateSalt()

        // Generate the update proof.
        let blsSecret: Data
        do {
            // onym:allow-secret-read
            blsSecret = try await identity.blsSecretKey()
        } catch {
            return .failed(.transportFailed("bls_secret: \(error)"))
        }

        // Pre-flight: confirm the active identity actually IS the
        // admin of this group before handing the secret to the
        // prover. Catches the common "Alice has switched identities,
        // her current keychain secret doesn't match the group's
        // stored admin BLS pubkey" case cleanly — without this check
        // the SDK would surface the same problem as a cryptic
        // `Poseidon(admin_secret_key) ≠ supplied leaf hash` error
        // ~3-5s later (after the prover's pre-witness checks fail).
        let activePubFromSecret: Data
        do {
            activePubFromSecret = try GroupCommitmentBuilder.computePublicKey(
                secretKey: blsSecret
            )
        } catch {
            return .failed(.transportFailed("derive_pub: \(error)"))
        }
        guard activePubFromSecret == group.members[adminIndexOld].publicKeyCompressed else {
            return .failed(.notAdminOfThisGroup)
        }
        let proofInput = GroupProofUpdateInput(
            groupType: .tyranny,
            tier: group.tier,
            oldMembers: group.members,
            adminBlsSecretKey: blsSecret,
            adminIndexOld: adminIndexOld,
            epochOld: group.epoch,
            memberRootNew: memberRootNew,
            groupID: group.groupIDData,
            saltOld: group.salt,
            saltNew: saltNew
        )
        let proof: GroupUpdateProof
        do {
            proof = try proofGenerator.proveUpdate(proofInput)
        } catch let err as GroupProofGeneratorError {
            return .failed(.proofFailed(err.localizedDescription))
        } catch {
            return .failed(.proofFailed(String(describing: error)))
        }

        // Submit to chain.
        let transport = makeContractTransport(relayerURL)
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .tyranny,
            network: activeNetwork.sepNetwork,
            transport: transport
        )
        let payload = TyrannyUpdateCommitmentPayload(
            groupID: group.groupIDData,
            proof: proof.proof,
            publicInputs: proof.publicInputs
        )
        let response: SEPSubmissionResponse
        do {
            response = try await client.updateCommitmentTyranny(payload)
        } catch {
            return .failed(.transportFailed("anchor: \(error)"))
        }
        guard response.accepted else {
            return .failed(.anchorRejected(response.message ?? "(no message)"))
        }

        // Build the updated local ChatGroup. `commitment` becomes
        // the proof's c_new (PI[2]); `epoch` advances by 1; `salt`
        // becomes saltNew; `members` becomes newMembers.
        let newEpoch = group.epoch + 1
        var updated = group
        updated.members = newMembers
        updated.commitment = proof.commitmentNew
        updated.epoch = newEpoch
        updated.salt = saltNew
        return .ok(updated)
    }

    /// Admin-side "remove member from a Tyranny group" flow, with
    /// groupSecret rotation. Ordering is anchor → persist → fan out
    /// (mirrors `performApprove`):
    ///
    ///  1. Shrink the roster, prove the Tyranny `update_commitment`
    ///     over the new Merkle root, submit to the relayer. Epoch
    ///     bumps, salt rotates, and — unlike a join — a **fresh random
    ///     groupSecret** is generated so the removed member holds no
    ///     post-removal member-only secret.
    ///  2. Persist the advanced local state (roster minus victim, the
    ///     victim's `MemberProfile` tombstoned via `revoked = true` —
    ///     never deleted, so past-message rendering and dedup keep
    ///     working).
    ///  3. Fan a `MemberRemovalPayload` out per recipient,
    ///     best-effort: remaining members receive the variant carrying
    ///     `group_secret_new` + `salt_new`; the victim receives the
    ///     secret-free variant (they learn the fact, never the
    ///     secrets).
    ///
    /// The fanout is deliberately OFF the critical path: once the
    /// chain anchor lands and local state persists, the removal is
    /// real — a member that misses the payload converges later via
    /// inbox replay. (stellar-mls postmortem lesson: never block the
    /// security-critical leg on courtesy delivery.)
    ///
    /// Mirrors `GroupMemberRemover.remove` from onym-android (where a
    /// shared `Mutex` stands in for this actor's `approvalChain`).
    private func performRemove(
        groupIDHex: String,
        victimBlsHex: String
    ) async -> RemoveOutcome {
        let victimHex = victimBlsHex.lowercased()
        let activeID = await identity.currentSelectedID()
        let groups = await groupRepository.currentGroups()
        // Scope to the active identity's copy — the same on-chain
        // group id can belong to two local identities, and only the
        // admin's copy holds the authority to shrink the roster.
        guard let group = groups.first(where: {
            $0.id.lowercased() == groupIDHex.lowercased()
                && (activeID == nil || $0.ownerIdentityID == activeID)
        }) else { return .unknownGroup }
        guard activeID != nil else { return .noIdentityLoaded }

        guard group.groupType == .tyranny else { return .notTyrannyGroup }
        guard let adminPubkeyHex = group.adminPubkeyHex?.lowercased() else {
            return .notAdminOfThisGroup
        }
        guard victimHex != adminPubkeyHex else { return .cannotRemoveSelf }

        guard let victimProfile = group.memberProfiles[victimHex] else {
            return .unknownMember
        }
        guard !victimProfile.revoked else { return .alreadyRemoved }

        let victimBytes = ChatGroup.bytes(fromHex: victimHex)
        guard group.members.contains(where: {
            $0.publicKeyCompressed == victimBytes
        }) else { return .memberNotInRoster }

        // ─── chain-anchor leg (mirrors anchorTyrannyJoin) ────────────
        guard let relayerURL = await relayers.selectURL() else {
            return .noActiveRelayer
        }
        let activeNetwork = networkPreference.current()
        let anchorKey = AnchorSelectionKey(
            network: activeNetwork.contractNetwork,
            type: .tyranny
        )
        guard let binding = await contracts.binding(for: anchorKey) else {
            return .noContractBinding
        }

        let adminBytes = ChatGroup.bytes(fromHex: adminPubkeyHex)
        guard let adminIndexOld = group.members.firstIndex(where: {
            $0.publicKeyCompressed == adminBytes
        }) else {
            return .transportFailed("admin not in members roster")
        }

        // Removal preserves the existing lex order — filtering can't
        // reorder an already-sorted roster.
        let newMembers = group.members.filter {
            $0.publicKeyCompressed != victimBytes
        }
        let memberRootNew: Data
        do {
            memberRootNew = try GroupCommitmentBuilder.computeMerkleRoot(
                members: newMembers,
                tier: group.tier
            )
        } catch {
            return .proofFailed("merkle_root: \(error)")
        }
        let saltNew = GroupCommitmentBuilder.generateSalt()
        // Fresh random groupSecret — the whole point of the rotation:
        // the victim keeps the OLD secret, which stops mattering the
        // moment the remaining members switch.
        let groupSecretNew: Data
        do {
            groupSecretNew = try SecureRandom.data(32)
        } catch {
            return .transportFailed("random: \(error)")
        }

        let blsSecret: Data
        do {
            // onym:allow-secret-read
            blsSecret = try await identity.blsSecretKey()
        } catch {
            return .transportFailed("bls_secret: \(error)")
        }

        // Same pre-flight as the approver: confirm the active identity
        // actually IS the admin before handing the secret to the
        // prover — catches "user switched identities" cleanly.
        let activePubFromSecret: Data
        do {
            activePubFromSecret = try GroupCommitmentBuilder.computePublicKey(
                secretKey: blsSecret
            )
        } catch {
            return .transportFailed("derive_pub: \(error)")
        }
        guard activePubFromSecret == group.members[adminIndexOld].publicKeyCompressed else {
            return .notAdminOfThisGroup
        }

        let proofInput = GroupProofUpdateInput(
            groupType: .tyranny,
            tier: group.tier,
            oldMembers: group.members,
            adminBlsSecretKey: blsSecret,
            adminIndexOld: adminIndexOld,
            epochOld: group.epoch,
            memberRootNew: memberRootNew,
            groupID: group.groupIDData,
            saltOld: group.salt,
            saltNew: saltNew
        )
        let proof: GroupUpdateProof
        do {
            proof = try proofGenerator.proveUpdate(proofInput)
        } catch let err as GroupProofGeneratorError {
            return .proofFailed(err.localizedDescription)
        } catch {
            return .proofFailed(String(describing: error))
        }

        let transport = makeContractTransport(relayerURL)
        let client = SEPContractClient(
            contractID: binding.contractID,
            contractType: .tyranny,
            network: activeNetwork.sepNetwork,
            transport: transport
        )
        let response: SEPSubmissionResponse
        do {
            response = try await client.updateCommitmentTyranny(
                TyrannyUpdateCommitmentPayload(
                    groupID: group.groupIDData,
                    proof: proof.proof,
                    publicInputs: proof.publicInputs
                )
            )
        } catch {
            return .transportFailed("anchor: \(error)")
        }
        guard response.accepted else {
            return .anchorRejected(response.message ?? "(no message)")
        }

        // ─── persist ─────────────────────────────────────────────────
        // The anchor landed: the removal is now the on-chain truth.
        // Persist BEFORE fanning out so a crash mid-fanout can't lose
        // the transition (peers converge via inbox replay).
        var anchored = group
        anchored.members = newMembers
        anchored.commitment = proof.commitmentNew
        anchored.epoch = group.epoch + 1
        anchored.salt = saltNew
        anchored.groupSecret = groupSecretNew
        anchored.memberProfiles[victimHex] = victimProfile.withRevoked(true)
        await groupRepository.insert(anchored)

        // ─── fan out (best-effort) ───────────────────────────────────
        await broadcastRemoval(
            in: anchored,
            victimHex: victimHex,
            victimProfile: victimProfile,
            adminHex: adminPubkeyHex,
            groupSecretNew: groupSecretNew,
            saltNew: saltNew
        )
        return .sent
    }

    /// One sealed envelope per recipient, sequential, failures
    /// swallowed. The victim's copy is encoded WITHOUT the rotated
    /// secrets — build both wire bodies once, outside the loop.
    ///
    /// ## Recovery path for a missed envelope
    ///
    /// If a recipient's send fails here (no relay accepted it), inbox
    /// replay can NOT redeliver — the envelope never reached a relay.
    /// That member's local state stays on the pre-removal epoch +
    /// groupSecret until something triggers a
    /// `GroupStateRefreshRequest` toward the admin (whose reply
    /// carries the full current snapshot). They remain SAFE in the
    /// meantime — the removal is already anchored and the victim
    /// can't read anything new — but they'll keep the victim in their
    /// local roster and keep sealing messages to the victim's inbox
    /// until they converge. A proactive resend queue is a known
    /// follow-up.
    ///
    /// Mirrors `GroupMemberRemover.broadcastRemoval` from onym-android.
    private func broadcastRemoval(
        in group: ChatGroup,
        victimHex: String,
        victimProfile: MemberProfile,
        adminHex: String,
        groupSecretNew: Data,
        saltNew: Data
    ) async {
        guard let commitment = group.commitment else { return }
        let sentAt = Int64(Date().timeIntervalSince1970 * 1000)
        let memberBytes: Data
        let victimBytes: Data
        do {
            let memberPayload = try MemberRemovalPayload(
                version: 1,
                groupID: group.groupIDData,
                removedBlsHex: victimHex,
                commitment: commitment,
                epoch: group.epoch,
                sentAtMillis: sentAt,
                groupSecretNew: groupSecretNew,
                saltNew: saltNew
            )
            let victimPayload = try MemberRemovalPayload(
                version: 1,
                groupID: group.groupIDData,
                removedBlsHex: victimHex,
                commitment: commitment,
                epoch: group.epoch,
                sentAtMillis: sentAt
            )
            memberBytes = try JSONEncoder().encode(memberPayload)
            victimBytes = try JSONEncoder().encode(victimPayload)
        } catch {
            // Encode failures can't happen for sizes the caller
            // already validated — but skipping fanout beats crashing
            // after the anchor landed.
            return
        }

        for (memberKey, profile) in group.memberProfiles {
            if memberKey == adminHex { continue } // self
            let body: Data
            if memberKey == victimHex {
                body = victimBytes
            } else {
                if profile.revoked { continue } // earlier tombstones
                body = memberBytes
            }
            let inboxKey = memberKey == victimHex
                ? victimProfile.inboxPublicKey
                : profile.inboxPublicKey
            let sealed: Data
            do {
                sealed = try await identity.sealInvitation(payload: body, to: inboxKey)
            } catch {
                continue
            }
            let tag = TransportInboxID(
                rawValue: IntroInboxPump.inboxTag(from: inboxKey)
            )
            // Receipts discarded — fan-out is best-effort; the on-chain
            // anchor is the truth and inbox replay backfills stragglers.
            _ = try? await inboxTransport.send(sealed, to: tag)
        }
    }

    /// Insert/update the joiner's `MemberProfile` on the local
    /// group. Idempotent — a second approval for the same joiner
    /// (e.g. they re-tap the link before the inviter notices the
    /// first request) overwrites the existing entry with the latest
    /// alias + inbox-pub. Re-inserting through `GroupRepository`
    /// goes through `SwiftDataGroupStore.insertOrUpdate`, which
    /// updates the row in place rather than minting a new one.
    private func recordJoiner(
        in group: ChatGroup,
        blsPub: Data,
        inboxPub: Data,
        sendingPub: Data,
        alias: String
    ) async {
        let key = blsPub.map { String(format: "%02x", $0) }.joined()
        var updated = group
        updated.memberProfiles[key] = MemberProfile(
            alias: alias,
            inboxPublicKey: inboxPub,
            sendingPubkey: sendingPub
        )
        await groupRepository.insert(updated)
    }

    /// Build a `MemberAnnouncementPayload` for the new joiner and
    /// fan it out to every existing member's inbox. Recipients =
    /// `group.memberProfiles ∖ {admin, new joiner}`. The admin
    /// already knows about the join (just recorded it locally); the
    /// joiner gets the full `GroupInvitationPayload` instead.
    ///
    /// Best-effort per recipient: a per-member transport failure is
    /// swallowed silently and the loop moves on. The receive-side
    /// (PR 6) is idempotent on `(groupId, blsPub)` so a future retry
    /// path could re-broadcast without creating duplicates.
    ///
    /// Empty fanout (single-member group, just-created) is a no-op.
    private func broadcastJoin(
        in group: ChatGroup,
        joinerBlsPub: Data,
        joinerInboxPub: Data,
        joinerSendingPub: Data,
        joinerAlias: String
    ) async {
        let adminAlias = await identity.currentIdentityName() ?? ""
        let announced: MemberAnnouncementPayload.AnnouncedMember
        do {
            announced = try MemberAnnouncementPayload.AnnouncedMember(
                blsPub: joinerBlsPub,
                inboxPub: joinerInboxPub,
                alias: joinerAlias,
                sendingPub: joinerSendingPub
            )
        } catch {
            // Wrong-sized BLS pubkey shouldn't happen — we already
            // built `recordJoiner`'s key from the same bytes — but
            // skipping fanout is safer than crashing.
            return
        }
        let payload: MemberAnnouncementPayload
        do {
            payload = try MemberAnnouncementPayload(
                version: 1,
                groupId: group.groupIDData,
                newMember: announced,
                adminAlias: adminAlias,
                // PR-13a: ship the post-anchor commitment + epoch
                // so PR-13b's receivers can verify against
                // `SEPContractClient.getCommitment`. nil only when
                // the calling group hasn't been anchored (legacy
                // / non-Tyranny path) — receivers fall back to
                // best-effort acceptance in that case.
                commitment: group.commitment,
                epoch: group.epoch
            )
        } catch {
            return
        }
        let payloadBytes: Data
        do {
            payloadBytes = try JSONEncoder().encode(payload)
        } catch {
            return
        }

        let joinerKey = joinerBlsPub.map { String(format: "%02x", $0) }.joined()
        let adminKey = group.adminPubkeyHex?.lowercased()

        for (memberKey, profile) in group.memberProfiles {
            // Skip self (admin already knows) + the new joiner
            // (covered by the GroupInvitationPayload above) + removed
            // members (tombstoned in place — their inbox gets nothing).
            if memberKey == joinerKey { continue }
            if let adminKey, memberKey == adminKey { continue }
            if profile.revoked { continue }

            let sealed: Data
            do {
                sealed = try await identity.sealInvitation(
                    payload: payloadBytes,
                    to: profile.inboxPublicKey
                )
            } catch {
                continue
            }
            let tag = TransportInboxID(
                rawValue: IntroInboxPump.inboxTag(from: profile.inboxPublicKey)
            )
            // Throw away the receipt — fanout is best-effort. A
            // member that misses one announcement will still see the
            // joiner in any subsequent group activity.
            _ = try? await inboxTransport.send(sealed, to: tag)
        }
    }

    /// Decline a pending request: drop it + revoke the intro slot.
    /// No NACK to the joiner — their JoinScreen times out.
    func decline(requestId: String) async {
        if let introPub = await findIntroPub(forRequestID: requestId) {
            await introKeyStore.revoke(introPublicKey: introPub)
        }
        await introRequestStore.consume(id: requestId)
    }

    // MARK: - Private

    private func subscribePending(
        id: UUID,
        continuation: AsyncStream<[PendingRequest]>.Continuation
    ) {
        pendingContinuations[id] = continuation
        continuation.yield(pendingValue)
    }

    private func unsubscribePending(id: UUID) {
        pendingContinuations.removeValue(forKey: id)
    }

    private func publishPending() {
        for cont in pendingContinuations.values { cont.yield(pendingValue) }
    }

    private func refresh(from raw: [IntroRequest]) async {
        // Collapse duplicates that represent the same logical join —
        // same joiner identity + same group. The joiner re-sends with a
        // fresh ephemeral Nostr key each time (accept-after-relaunch,
        // deeplink re-open, retries), so every copy is a distinct event
        // with its own id; `IntroRequestStore`'s event-id dedup can't
        // catch them. Without this, one person retrying shows as several
        // rows and approving/declining one leaves the siblings behind —
        // which reads as "the buttons don't work". Keep the most recently
        // received copy, positioned at the first-seen index.
        var collapsed: [String: (request: PendingRequest, receivedAt: Date)] = [:]
        var order: [String] = []
        for r in raw {
            guard let p = await decode(r) else { continue }
            let identity = p.joinerBlsPublicKey ?? p.joinerInboxPublicKey
            let key = Self.hex(identity) + ":" + Self.hex(p.groupId)
            if let existing = collapsed[key] {
                if r.receivedAt > existing.receivedAt {
                    collapsed[key] = (p, r.receivedAt)
                }
            } else {
                collapsed[key] = (p, r.receivedAt)
                order.append(key)
            }
        }
        pendingValue = order.compactMap { collapsed[$0]?.request }
        publishPending()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ raw: IntroRequest) async -> PendingRequest? {
        guard let entry = await introKeyStore.find(introPublicKey: raw.targetIntroPublicKey) else {
            // Entry was already revoked, or the request landed on a
            // pubkey we never minted (forged). Drop silently.
            return nil
        }
        let privKey: Curve25519.KeyAgreement.PrivateKey
        do {
            privKey = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: entry.introPrivateKey
            )
        } catch {
            decryptFailures += 1
            return nil
        }
        let plaintext: Data
        do {
            plaintext = try IdentityRepository.decryptSealedEnvelope(
                envelopeBytes: raw.payload,
                recipientX25519PrivateKey: privKey
            )
        } catch {
            decryptFailures += 1
            return nil
        }
        let payload: JoinRequestPayload
        do {
            payload = try JSONDecoder().decode(JoinRequestPayload.self, from: plaintext)
        } catch {
            decryptFailures += 1
            return nil
        }
        // Joiner is asking about a different group than the intro
        // entry was minted for. Forged or stale link — drop silently.
        guard payload.groupId == entry.groupId else {
            decryptFailures += 1
            return nil
        }
        let groups = await groupRepository.currentGroups()
        let groupName = groups.first(where: { $0.groupIDData == payload.groupId })?.name
        return PendingRequest(
            id: raw.id,
            joinerInboxPublicKey: payload.joinerInboxPublicKey,
            joinerBlsPublicKey: payload.joinerBlsPublicKey,
            joinerLeafHash: payload.joinerLeafHash,
            joinerSendingPublicKey: payload.joinerSendingPublicKey,
            joinerDisplayLabel: payload.joinerDisplayLabel,
            groupId: payload.groupId,
            groupName: groupName
        )
    }

    /// `PendingRequest` doesn't carry the introPub (intentional —
    /// UI never needs it). Resolve via the raw store on demand.
    private func findIntroPub(forRequestID id: String) async -> Data? {
        let raw = await introRequestStore.current()
        return raw.first { $0.id == id }?.targetIntroPublicKey
    }
}
