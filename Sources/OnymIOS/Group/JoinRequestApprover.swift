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
    func approve(requestId: String) async -> ApproveOutcome {
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
            memberProfiles: anchored.memberProfiles.isEmpty ? nil : anchored.memberProfiles
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
                alias: req.joinerDisplayLabel
            )
            await broadcastJoin(
                in: anchored,
                joinerBlsPub: blsPub,
                joinerInboxPub: req.joinerInboxPublicKey,
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
        alias: String
    ) async {
        let key = blsPub.map { String(format: "%02x", $0) }.joined()
        var updated = group
        updated.memberProfiles[key] = MemberProfile(
            alias: alias,
            inboxPublicKey: inboxPub
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
        joinerAlias: String
    ) async {
        let adminAlias = await identity.currentIdentityName() ?? ""
        let announced: MemberAnnouncementPayload.AnnouncedMember
        do {
            announced = try MemberAnnouncementPayload.AnnouncedMember(
                blsPub: joinerBlsPub,
                inboxPub: joinerInboxPub,
                alias: joinerAlias
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
            // (covered by the GroupInvitationPayload above).
            if memberKey == joinerKey { continue }
            if let adminKey, memberKey == adminKey { continue }

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
        var decoded: [PendingRequest] = []
        for r in raw {
            if let p = await decode(r) { decoded.append(p) }
        }
        pendingValue = decoded
        publishPending()
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
