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
    }

    private let identity: IdentityRepository
    private let introKeyStore: any IntroKeyStore
    private let introRequestStore: any IntroRequestStore
    private let groupRepository: GroupRepository
    private let inboxTransport: any InboxTransport

    private var pendingValue: [PendingRequest] = []
    private var pendingContinuations: [UUID: AsyncStream<[PendingRequest]>.Continuation] = [:]
    private var decryptFailures: Int = 0
    private var collectorTask: Task<Void, Never>?

    init(
        identity: IdentityRepository,
        introKeyStore: any IntroKeyStore,
        introRequestStore: any IntroRequestStore,
        groupRepository: GroupRepository,
        inboxTransport: any InboxTransport
    ) {
        self.identity = identity
        self.introKeyStore = introKeyStore
        self.introRequestStore = introRequestStore
        self.groupRepository = groupRepository
        self.inboxTransport = inboxTransport
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

    /// Approve a pending request: build the `GroupInvitationPayload`
    /// from the local group state, seal to the joiner's inbox key,
    /// ship via Nostr, then revoke the intro slot + drop the
    /// pending entry.
    func approve(requestId: String) async -> ApproveOutcome {
        guard let req = pendingValue.first(where: { $0.id == requestId }) else {
            return .unknownRequest
        }
        guard await identity.currentIdentity() != nil else {
            return .noIdentityLoaded
        }
        let groups = await groupRepository.currentGroups()
        guard let group = groups.first(where: { $0.groupIDData == req.groupId }) else {
            return .unknownGroup
        }
        let invite = GroupInvitationPayload(
            version: 1,
            groupID: group.groupIDData,
            groupSecret: group.groupSecret,
            name: group.name,
            members: group.members,
            epoch: group.epoch,
            salt: group.salt,
            commitment: group.commitment,
            tierRaw: group.tier.rawValue,
            groupTypeRaw: group.groupType.rawValue,
            adminPubkeyHex: group.adminPubkeyHex
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
        // so the admin sees their alias in the UI. Skipped when the
        // joiner's BLS pubkey isn't on the wire (pre-PR-4 build) —
        // there's no stable cross-device key to record under, and
        // PR 5's announcement fanout would skip them anyway. The
        // sealed invite has already shipped at this point, so a
        // failure here doesn't leak; we just live with a missing
        // directory entry until the next message.
        if let blsPub = req.joinerBlsPublicKey {
            await recordJoiner(
                in: group,
                blsPub: blsPub,
                inboxPub: req.joinerInboxPublicKey,
                alias: req.joinerDisplayLabel
            )
        }
        // Best-effort cleanup. Both calls run regardless of failures
        // because the request is conceptually consumed at this point;
        // a leaked intro key is benign.
        if let introPub = await findIntroPub(forRequestID: requestId) {
            await introKeyStore.revoke(introPublicKey: introPub)
        }
        await introRequestStore.consume(id: requestId)
        return .sent
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
