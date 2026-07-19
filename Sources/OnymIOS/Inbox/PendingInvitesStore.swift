import Foundation

/// One decoded `GroupInviteOfferPayload` awaiting the user's explicit
/// Accept / Dismiss. Unlike `IncomingInvitation` (opaque ciphertext),
/// the offer is decrypted + decoded at receive time by
/// `IncomingMessageDispatcher`, so this record carries the structured
/// fields the UI needs to render "X invited you to Y" and the intro
/// public key the Accept action replies to.
struct PendingInvite: Identifiable, Equatable, Sendable {
    /// Nostr event id of the inbound offer — the dedupe + consume key.
    let id: String
    /// Identity the offer was delivered to (the inbox tag it arrived
    /// on). The Accept action replies *as* this identity.
    let ownerIdentityID: IdentityID
    /// Admin's per-invite intro pubkey — the reply channel the join
    /// request is sealed to.
    let introPublicKey: Data
    let groupID: Data
    let groupName: String?
    let inviterAlias: String
    /// Optional free-text invitation the creator wrote — shown on the
    /// invite card so the user reads it before accepting. `nil` = none.
    let invitationMessage: String?
    let receivedAt: Date
}

/// Receive-side seam the dispatcher writes decoded offers into. Kept
/// minimal (one method) so the dispatcher depends on a narrow protocol
/// rather than the concrete store.
protocol PendingInvitesRecording: Sendable {
    /// Idempotent on `PendingInvite.id`. Re-delivery of the same offer
    /// (replaceable Nostr event re-fetched on relaunch) is a no-op.
    func record(_ invite: PendingInvite) async
}

/// Process-lifetime store of pending invites, filtered by the
/// currently-selected identity. In-memory by design: the offer itself
/// is a retained Nostr event, so the inbox fan-out re-delivers it on
/// every launch — exactly like `InMemoryIntroRequestStore` for join
/// requests. Snapshots mirror `IncomingInvitationsRepository`'s
/// per-identity filtering so the list flips when the user switches
/// identity.
actor PendingInvitesStore: PendingInvitesRecording {
    private var all: [PendingInvite] = []
    private var currentIdentity: IdentityID?
    private var continuations: [UUID: AsyncStream<[PendingInvite]>.Continuation] = [:]

    init() {}

    func record(_ invite: PendingInvite) async {
        guard !all.contains(where: { $0.id == invite.id }) else { return }
        all.append(invite)
        publish()
    }

    /// Drop an invite after the user accepted or dismissed it.
    func consume(id: String) {
        let before = all.count
        all.removeAll { $0.id == id }
        if all.count != before { publish() }
    }

    /// Cascade for the identity-removal flow.
    func removeForOwner(_ id: IdentityID) {
        let before = all.count
        all.removeAll { $0.ownerIdentityID == id }
        if all.count != before { publish() }
    }

    /// Drop every pending invite whose group now exists locally — the
    /// admin approved + the `GroupInvitationPayload` materialized the
    /// group, so the offer has served its purpose. Called by the flow
    /// when `GroupRepository` emits.
    func consumeForMaterializedGroups(_ groupIDs: Set<Data>) {
        guard !groupIDs.isEmpty else { return }
        let before = all.count
        all.removeAll { groupIDs.contains($0.groupID) }
        if all.count != before { publish() }
    }

    func setCurrentIdentity(_ id: IdentityID?) {
        currentIdentity = id
        publish()
    }

    /// Hot stream of pending invites for the current identity, newest
    /// first. New subscribers get the current snapshot immediately.
    nonisolated var snapshots: AsyncStream<[PendingInvite]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    private func subscribe(
        id: UUID,
        continuation: AsyncStream<[PendingInvite]>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(filtered())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func filtered() -> [PendingInvite] {
        guard let currentIdentity else { return [] }
        return all
            .filter { $0.ownerIdentityID == currentIdentity }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    private func publish() {
        let snapshot = filtered()
        for cont in continuations.values { cont.yield(snapshot) }
    }
}
