import CryptoKit
import Foundation
import OnymTransport
import OnymChain
import OnymIdentity

/// Test seam used by `ApproveRequestsFlow`. The production conformer
/// is `JoinRequestApprover` itself; tests inject a stub instead of
/// standing up the full keychain + transport stack just to exercise
/// the flow's bookkeeping.
public protocol JoinRequestApproving: Sendable {
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
///     inbox key and ships it. The intro key is NOT retired.
///  4. On Decline → drop that one request; the link stays live.
public actor JoinRequestApprover: JoinRequestApproving {

    /// Whether the joiner agreed to the group's rules, decided once
    /// when the request is decrypted and against the group's own copy
    /// of the text.
    ///
    /// Five outcomes rather than a `Bool`, because a founder deciding
    /// on a stranger needs to tell apart the cases a `Bool` collapses:
    /// someone who signed nothing (an older build) is not someone whose
    /// signature failed to verify (forged or corrupt), and neither is
    /// someone who agreed to a previous wording. Only one of the three
    /// is worth asking the joiner to redo.
    public enum RulesAgreement: Equatable, Sendable {
        /// The group has no rules, so there was nothing to agree to.
        case notRequired
        /// Verified against the rules this group holds right now.
        case agreed
        /// A signature this device cannot check, because the hash it
        /// carries is not the hash of any rules we hold.
        ///
        /// Named for what is known rather than for what it suggests.
        /// The earlier name — "agreed to other rules" — asserted an
        /// agreement nothing here verified: the only evidence is the
        /// joiner's *own* hash differing from ours, which they choose.
        /// Sixty-four random bytes and a random hash landed in this
        /// case, and it was the reassuring one, so a forgery could pick
        /// its own verdict by not echoing our hash. It reads as
        /// "can't be checked" now, and is coloured accordingly.
        case unknownRules
        /// A signature that doesn't verify. Not an old client: an old
        /// client sends none at all.
        case invalid
        /// The group has rules and the request carried no agreement.
        case notSigned
    }

    /// UI-renderable view of one decrypted, awaiting-action request.
    public struct PendingRequest: Equatable, Sendable, Identifiable {
        /// Stable id == `IntroRequest.id`. Approve / Decline use it
        /// as the dedupe key.
        public let id: String
        public let joinerInboxPublicKey: Data
        /// 48-byte BLS pubkey when the joiner sent it (current
        /// builds always do). `nil` when the request came from a
        /// pre-PR-4 client; the approver still ships the invitation
        /// back, but skips the local roster update because there's
        /// no stable cross-device key to record under.
        public let joinerBlsPublicKey: Data?
        /// 32-byte Poseidon leaf hash. Required for Tyranny approve:
        /// the admin can't generate the on-chain `update_commitment`
        /// proof without it (it's the joiner's leaf in the new tree).
        /// `nil` when the joiner shipped a pre-PR-13 request — those
        /// requests can't be approved on-chain and surface as
        /// `.outdatedJoinerClient`.
        public let joinerLeafHash: Data?
        /// 32-byte Ed25519 raw pubkey — joiner's
        /// `Identity.stellarPublicKey`. Plumbed through to the
        /// joiner's `MemberProfile` and the fan-out
        /// `MemberAnnouncementPayload` so existing members can
        /// verify the joiner's chat-message envelope signatures
        /// (PR 4).
        public let joinerSendingPublicKey: Data
        public let joinerDisplayLabel: String
        public let groupId: Data
        /// Looked up from the local `GroupRepository`. nil if the
        /// joiner is asking about a group we don't know — surface a
        /// "this invite isn't for any group on this device" error
        /// in the UI rather than approving.
        public let groupName: String?
        /// What the joiner agreed to, checked against the group's rules
        /// at decrypt time. Never blocks approval on its own — the
        /// founder is shown it and decides, because rejecting outright
        /// would silently exclude every joiner on a build that predates
        /// rules, including the whole of the other platform until it
        /// ships.
        public let rulesAgreement: RulesAgreement
        /// The signature itself, kept so approval can record it on the
        /// member. Retained rather than re-derived: this is the
        /// evidence.
        public let rulesSignature: Data?
        /// The hash the joiner signed over — which is not necessarily
        /// the hash of this group's current rules; see
        /// `agreedToOtherRules`.
        public let rulesHash: Data?

        public init(
            id: String,
            joinerInboxPublicKey: Data,
            joinerBlsPublicKey: Data?,
            joinerLeafHash: Data?,
            joinerSendingPublicKey: Data,
            joinerDisplayLabel: String,
            groupId: Data,
            groupName: String?,
            // No defaults: forgetting the verdict would read as "this
            // group has no rules", which is a claim, and the compiler
            // is the cheapest place to catch it.
            rulesAgreement: RulesAgreement,
            rulesSignature: Data?,
            rulesHash: Data?
        ) {
            self.id = id
            self.joinerInboxPublicKey = joinerInboxPublicKey
            self.joinerBlsPublicKey = joinerBlsPublicKey
            self.joinerLeafHash = joinerLeafHash
            self.joinerSendingPublicKey = joinerSendingPublicKey
            self.joinerDisplayLabel = joinerDisplayLabel
            self.groupId = groupId
            self.groupName = groupName
            self.rulesAgreement = rulesAgreement
            self.rulesSignature = rulesSignature
            self.rulesHash = rulesHash
        }
    }

    public enum ApproveOutcome: Equatable, Sendable {
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
        /// The contract has no record of this group yet
        /// (`GroupNotFound`). Almost always a race rather than a fault:
        /// the group's own `create_group` transaction is still waiting
        /// to be included in a ledger, and the admin approved a joiner
        /// within those few seconds. Retrying shortly succeeds, so this
        /// is separated from `anchorRejected` — which means "the chain
        /// looked at this and said no" and is not worth retrying.
        case groupNotAnchoredYet
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
    /// Appends the "X joined" notice to the admin's own copy of the
    /// thread once an approval lands. Every other member gets theirs
    /// from the fanned-out `MemberAnnouncementPayload`; the admin never
    /// receives that (it's the sender), so this is the admin's only
    /// source for the row.
    private let systemEvents: any GroupSystemEventRecording

    private var pendingValue: [PendingRequest] = []
    /// Surviving row id → every raw id that collapsed into it.
    /// Rebuilt by `refresh`, read by `consumeRequestAndSiblings`.
    private var collapsedRequestIDs: [String: [String]] = [:]
    private var pendingContinuations: [UUID: AsyncStream<[PendingRequest]>.Continuation] = [:]
    private var decryptFailures: Int = 0
    /// Request ids already counted in `decryptFailures`, so a re-decode
    /// of the same undecodable row doesn't inflate the signal.
    private var countedDecodeFailures: Set<String> = []
    private var collectorTask: Task<Void, Never>?
    /// Serializes `approve` calls. Each approval reads `group.epoch`,
    /// proves an `update_commitment` from it, submits, then persists
    /// `epoch + 1`. The actor re-enters at the multi-second prove /
    /// submit awaits, so two overlapping approvals would both read the
    /// same stale epoch — the chain accepts the first and rejects the
    /// second as a stale-epoch replay (the loser's join silently
    /// fails). Chaining each approval onto the previous one's
    /// completion guarantees the read-prove-submit-persist critical
    /// section runs to completion before the next begins.
    private var approvalChain: Task<ApproveOutcome, Never>?

    public init(
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
        },
        systemEvents: any GroupSystemEventRecording = NoopGroupSystemEventRecorder()
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
        self.systemEvents = systemEvents
    }

    /// Hot stream of decoded pending requests. Replays the current
    /// snapshot to new subscribers; re-emits on every change.
    public nonisolated var pending: AsyncStream<[PendingRequest]> {
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

    private func countDecodeFailureOnce(_ requestID: String) {
        guard countedDecodeFailures.insert(requestID).inserted else { return }
        decryptFailures += 1
    }

    /// Subscribe to `IntroRequestStore.requests` and keep `pending`
    /// in sync. Idempotent — a second call replaces the prior
    /// collector. The collector runs until `stop` or actor deinit.
    public func start() {
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
    public func pumpOnce() async {
        let raw = await introRequestStore.current()
        await refresh(from: raw)
    }

    /// Public entry point. Serializes onto any in-flight approval via
    /// `approvalChain` so each on-chain `update_commitment` reads the
    /// epoch the previous approval persisted, then defers to
    /// `performApprove` for the actual anchor flow. The read-and-assign
    /// of `approvalChain` is synchronous (no `await` between), so
    /// overlapping callers chain deterministically.
    public func approve(requestId: String) async -> ApproveOutcome {
        let previous = approvalChain
        let task = Task { () -> ApproveOutcome in
            _ = await previous?.value
            return await self.performApprove(requestId: requestId)
        }
        approvalChain = task
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
    ///      to existing members, consume the request. The key survives.
    ///   8. A joiner already in `members` skips 2-6; snapshot only.
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

        // Already in the roster (reinstall, replay, retry) — re-anchoring
        // would duplicate a leaf. `members`, not `memberProfiles`.
        let alreadyInRoster = req.joinerBlsPublicKey.map { blsPub in
            group.members.contains { $0.publicKeyCompressed == blsPub }
        } ?? false

        // PR-13a admin-anchor path is Tyranny-only. Other types fall
        // through to the pre-PR-13 ship-only flow at the bottom.
        var anchored = group
        if group.groupType == .tyranny, !alreadyInRoster {
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

        // The directory the joiner will land with, including their own
        // row.
        //
        // Their own row has to come from here, because it is the one
        // thing about themselves they cannot reconstruct: this device
        // holds the signature they sent, and their device kept no copy
        // of it. Without this they arrive to find themselves marked as
        // never having signed the rules they had just agreed to — on
        // the one screen where their agreement is the point.
        var invitedProfiles = anchored.memberProfiles
        if let blsPub = req.joinerBlsPublicKey {
            let key = blsPub.map { String(format: "%02x", $0) }.joined()
            invitedProfiles[key] = MemberProfile(
                alias: req.joinerDisplayLabel,
                inboxPublicKey: req.joinerInboxPublicKey,
                sendingPubkey: req.joinerSendingPublicKey,
                rulesHash: req.rulesHash,
                rulesSignature: req.rulesSignature,
                rulesText: anchored.invitationMessage
            )
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
            // peers + admin by name from the moment they land — plus
            // their own row, for the agreement they can't rebuild
            // themselves. The receiver still overwrites the alias and
            // keys in it with its own; see the materializer.
            memberProfiles: invitedProfiles.isEmpty ? nil : invitedProfiles,
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
            // Idempotent, and the point of the re-join path: a
            // reinstalled joiner has a new inbox pubkey.
            // The agreement is recorded whatever it said, including
            // when it didn't verify. The founder saw the verdict and
            // approved anyway; keeping the bytes is what lets that
            // decision be re-examined later, and dropping them would
            // make "approved someone who signed nothing" and "approved
            // someone whose signature was wrong" indistinguishable
            // after the fact.
            await recordJoiner(
                in: anchored,
                blsPub: blsPub,
                inboxPub: req.joinerInboxPublicKey,
                sendingPub: req.joinerSendingPublicKey,
                alias: req.joinerDisplayLabel,
                rulesHash: req.rulesHash,
                rulesSignature: req.rulesSignature
            )
            // Deliberately NOT gated on `alreadyInRoster`. That flag
            // reads `members` (the crypto roster, advanced by the
            // anchor), while receivers dedupe on `memberProfiles` —
            // and those two diverge in exactly the case retry exists
            // to repair: the anchor persisted, then seal/send failed,
            // so the joiner is in `members` while no other member has
            // heard of them. Skipping here would leave their messages
            // parked forever. Both calls are idempotent at the
            // receiver — `applyAnnouncement` bails on a known BLS hex,
            // and the notice's id derives from `member-joined:<hex>`
            // over an idempotent insert — so a genuine re-join costs
            // some wasted seals, never a duplicate.
            await broadcastJoin(
                in: anchored,
                joinerBlsPub: blsPub,
                joinerInboxPub: req.joinerInboxPublicKey,
                joinerSendingPub: req.joinerSendingPublicKey,
                joinerAlias: req.joinerDisplayLabel,
                // Fanned out with the rest of the profile: every
                // member holds `sendingPub`, so every member can check
                // this. Kept to the founder, the evidence would reach
                // nobody who joined earlier.
                rulesHash: req.rulesHash,
                rulesSignature: req.rulesSignature
            )
            // The admin's own "X joined" row. Everyone else derives
            // theirs from the announcement fanned out just above,
            // which the admin — as its sender — never receives.
            await systemEvents.recordMemberJoined(
                groupID: anchored.id,
                ownerIdentityID: anchored.ownerIdentityID,
                groupType: anchored.groupType,
                joinerBlsPubkeyHex: blsPub.map { String(format: "%02x", $0) }.joined(),
                alias: req.joinerDisplayLabel,
                at: Date()
            )
        }
        // A create-time offer key is 1:1 with one named invitee and is
        // spent the moment that invitee is in. Leaving it live would
        // hold a relay subscription for good and leave a private link
        // redeemable by anyone it leaked to — retire it here rather
        // than hoping the host finds the invite list. The shared link
        // is untouched: that one is meant to be multi-use.
        await revokeSpentOfferKey(forRequestID: requestId, in: anchored)

        // Drop the request and its siblings. The shared key stays
        // alive, or every other joiner's row would silently vanish.
        await consumeRequestAndSiblings(requestId)
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
            // A refused call arrives as a non-2xx whose body carries the
            // simulation output, so the contract's own error number is
            // in there rather than in a structured field.
            if let sepError = error as? SEPError,
               sepError.contractErrorCode == SEPContractErrorCode.groupNotFound.rawValue {
                return .failed(.groupNotAnchoredYet)
            }
            return .failed(.transportFailed("anchor: \(error)"))
        }
        guard response.accepted else {
            // The same condition can also come back as a 200 with
            // `accepted: false`, depending on where the relayer catches
            // it — so both paths check.
            let message = response.message ?? "(no message)"
            if SEPContractErrorCode.parse(fromDiagnostics: message)
                == SEPContractErrorCode.groupNotFound.rawValue {
                return .failed(.groupNotAnchoredYet)
            }
            return .failed(.anchorRejected(message))
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
        sendingPub: Data,
        alias: String,
        rulesHash: Data?,
        rulesSignature: Data?
    ) async {
        let key = blsPub.map { String(format: "%02x", $0) }.joined()
        var updated = group
        updated.memberProfiles[key] = MemberProfile(
            alias: alias,
            inboxPublicKey: inboxPub,
            sendingPubkey: sendingPub,
            rulesHash: rulesHash,
            rulesSignature: rulesSignature,
            // This device's own copy, as of the approval — the text the
            // verdict above was reached against. Kept whatever that
            // verdict was: it is what the founder decided in front of,
            // and re-reading the decision later needs the words, not a
            // pointer to whatever the group says by then.
            rulesText: group.invitationMessage
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
        joinerAlias: String,
        rulesHash: Data?,
        rulesSignature: Data?
    ) async {
        let adminAlias = await identity.currentIdentityName() ?? ""
        let announced: MemberAnnouncementPayload.AnnouncedMember
        do {
            announced = try MemberAnnouncementPayload.AnnouncedMember(
                blsPub: joinerBlsPub,
                inboxPub: joinerInboxPub,
                alias: joinerAlias,
                sendingPub: joinerSendingPub,
                rulesHash: rulesHash,
                rulesSignature: rulesSignature,
                rulesText: group.invitationMessage
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

    /// Drop that one request and its siblings, and remember the
    /// joiner. A decline judges one requester, not the link — the link
    /// stays live for everyone else — but it has to mean something:
    /// the joiner's screen offers a retry, and each retry is a fresh
    /// Nostr event, so an id-keyed tombstone would let a declined
    /// stranger refill the queue indefinitely. Keyed on the collapse
    /// key (joiner identity ⊕ group), which survives that.
    /// No NACK to the joiner.
    public func decline(requestId: String) async {
        if let target = pendingValue.first(where: { $0.id == requestId }) {
            await introRequestStore.recordDeclined(
                collapseKey: Self.collapseKey(for: target)
            )
        }
        await consumeRequestAndSiblings(requestId)
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
        // Re-decodes each emission, so a row lives only while its key
        // does — stable now that approve no longer revokes.
        let declined = await introRequestStore.declinedCollapseKeys()
        var collapsed: [String: (request: PendingRequest, receivedAt: Date)] = [:]
        var siblings: [String: [String]] = [:]
        var order: [String] = []
        for r in raw {
            guard let p = await decode(r) else { continue }
            let key = Self.collapseKey(for: p)
            // Declined joiners stay declined across retries and
            // relaunches; the link itself is unaffected.
            if declined.contains(key) { continue }
            siblings[key, default: []].append(r.id)
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
        // Approve/Decline consume the whole set; dropping only the
        // winner lets a sibling resurface on the next emission.
        collapsedRequestIDs = order.reduce(into: [:]) { acc, key in
            guard let winner = collapsed[key]?.request else { return }
            acc[winner.id] = siblings[key] ?? [winner.id]
        }
        publishPending()
    }

    /// Drop `requestId` plus every sibling that collapsed into its row.
    /// The intro key is left alive — see the type doc.
    /// Revoke the per-invitee offer key this joiner came in on, if
    /// any. Matched on the label, which `CreateGroupInteractor` stamps
    /// with the invitee's inbox fingerprint.
    ///
    /// Matched on the link the request actually arrived on, NOT the
    /// joiner's fingerprint. A fingerprint match broke twice: a
    /// reinstalled joiner presents a fresh inbox key, so their offer
    /// key would never be retired and would hold a private link and its
    /// subscription open for good; and two invitees can collide on four
    /// bytes, so it would revoke a bystander's link alongside the spent
    /// one. The intro pubkey is unambiguous.
    ///
    /// `label != nil` is what separates a create-time offer from the
    /// group's shared link, which is meant to be multi-use and is never
    /// retired here.
    private func revokeSpentOfferKey(forRequestID requestID: String, in group: ChatGroup) async {
        let raw = await introRequestStore.current()
        guard let introPub = raw.first(where: { $0.id == requestID })?.targetIntroPublicKey,
              let entry = await introKeyStore.find(introPublicKey: introPub),
              entry.label != nil,
              entry.groupId == group.groupIDData
        else { return }
        await introKeyStore.revoke(introPublicKey: introPub)
    }

    private func consumeRequestAndSiblings(_ requestId: String) async {
        var ids = Set(collapsedRequestIDs[requestId] ?? [requestId])
        // The cached map is only as fresh as the last `refresh`, so
        // re-derive against the live store before consuming.
        if let target = pendingValue.first(where: { $0.id == requestId }) {
            let key = Self.collapseKey(for: target)
            for raw in await introRequestStore.current() {
                guard let decoded = await decode(raw),
                      Self.collapseKey(for: decoded) == key
                else { continue }
                ids.insert(raw.id)
            }
        }
        for id in ids {
            await introRequestStore.consume(id: id)
        }
    }

    /// Same joiner, same group — the identity two copies of one logical
    /// join share.
    private static func collapseKey(for request: PendingRequest) -> String {
        let identity = request.joinerBlsPublicKey ?? request.joinerInboxPublicKey
        return hex(identity) + ":" + hex(request.groupId)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ raw: IntroRequest) async -> PendingRequest? {
        guard let entry = await introKeyStore.find(introPublicKey: raw.targetIntroPublicKey) else {
            // Entry was revoked or rotated away, or the request landed
            // on a pubkey we never minted (forged). Counted like every
            // other decode failure: now that links are retired only
            // deliberately, this is what a request against a retired
            // link looks like, and it was the one drop with no signal
            // at all.
            //
            // Counted once per request id. `refresh` re-decodes the
            // whole raw set on every store publish and a request
            // against a retired link is never consumed, so a running
            // total would climb without bound off one dead link and
            // couldn't be told apart from a thousand real replays.
            countDecodeFailureOnce(raw.id)
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
        let group = groups.first(where: { $0.groupIDData == payload.groupId })
        return PendingRequest(
            id: raw.id,
            joinerInboxPublicKey: payload.joinerInboxPublicKey,
            joinerBlsPublicKey: payload.joinerBlsPublicKey,
            joinerLeafHash: payload.joinerLeafHash,
            joinerSendingPublicKey: payload.joinerSendingPublicKey,
            joinerDisplayLabel: payload.joinerDisplayLabel,
            groupId: payload.groupId,
            groupName: group?.name,
            rulesAgreement: Self.agreement(
                for: payload,
                rules: group?.invitationMessage
            ),
            rulesSignature: payload.rulesSignature,
            rulesHash: payload.rulesHash
        )
    }

    /// Decide the agreement once, here, where the group's own rules are
    /// in hand — rather than handing a signature to a view and asking
    /// it to work out what to make of it.
    static func agreement(
        for payload: JoinRequestPayload,
        rules: String?
    ) -> RulesAgreement {
        guard let rules = GroupRules.normalized(rules) else { return .notRequired }
        guard let signature = payload.rulesSignature,
              let signedHash = payload.rulesHash
        else { return .notSigned }
        // Checked against the group's text before the hash is compared,
        // so a joiner can't pass by echoing back the right hash with a
        // signature over something else: verification uses *our* rules,
        // and the hash they sent only ever explains a failure.
        if GroupRules.isAgreement(
            signature: signature,
            rules: rules,
            groupID: payload.groupId,
            joinerSendingPublicKey: payload.joinerSendingPublicKey
        ) {
            return .agreed
        }
        // Claimed our exact rules and failed against them: not an old
        // client, not another version, and nothing else this can be.
        // Claimed some other text, and we have no copy of it to check
        // against — so we say that, rather than calling it agreement.
        return signedHash == GroupRules.hash(rules) ? .invalid : .unknownRules
    }
}
