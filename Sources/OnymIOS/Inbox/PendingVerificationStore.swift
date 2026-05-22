import Foundation

/// A Tyranny group whose invitation snapshot couldn't be verified at an
/// exact epoch (the chain had advanced past it), so it's awaiting a
/// fresh snapshot from the admin before it may materialize. Kept OUT of
/// the chats list — an unverifiable snapshot must never look like a real
/// chat — and surfaced in the Invitations UI so the user knows a join is
/// in flight (or stuck because the admin is offline).
struct PendingGroupVerification: Identifiable, Equatable, Sendable {
    enum Status: Sendable, Equatable {
        /// Refresh request sent; waiting for the admin's reply.
        case verifying
        /// No reply within the timeout (or no admin inbox to ask) —
        /// surfaced to the user with a Retry.
        case unreachable
    }

    /// Dedupe key — one pending verification per group.
    var id: String { groupIDHex }
    let groupIDHex: String
    let ownerIdentityID: IdentityID
    let groupName: String
    var status: Status
    let receivedAt: Date
}

/// In-memory, per-identity-filtered store of groups awaiting
/// verification. In-memory by design: the stale invitation is a retained
/// Nostr event re-delivered on every launch, so the verifier re-defers
/// and re-requests on relaunch — same model as `PendingInvitesStore`.
actor PendingVerificationStore {
    private var all: [PendingGroupVerification] = []
    private var currentIdentity: IdentityID?
    private var continuations: [UUID: AsyncStream<[PendingGroupVerification]>.Continuation] = [:]

    init() {}

    /// Idempotent on `groupIDHex`. A re-deferred snapshot (re-delivery)
    /// keeps the existing entry/status rather than resetting it.
    func record(_ entry: PendingGroupVerification) {
        guard !all.contains(where: { $0.groupIDHex == entry.groupIDHex }) else { return }
        all.append(entry)
        publish()
    }

    func updateStatus(groupIDHex: String, status: PendingGroupVerification.Status) {
        guard let idx = all.firstIndex(where: { $0.groupIDHex == groupIDHex }) else { return }
        guard all[idx].status != status else { return }
        all[idx].status = status
        publish()
    }

    func contains(groupIDHex: String) -> Bool {
        all.contains { $0.groupIDHex == groupIDHex }
    }

    func status(groupIDHex: String) -> PendingGroupVerification.Status? {
        all.first { $0.groupIDHex == groupIDHex }?.status
    }

    /// Flip `.verifying → .unreachable` only if still verifying. Atomic
    /// on the store actor, so a stale timeout can't clobber an entry
    /// that was resolved-then-re-recorded between the timer firing and
    /// this call.
    func markUnreachableIfVerifying(groupIDHex: String) {
        guard let idx = all.firstIndex(where: { $0.groupIDHex == groupIDHex }),
              all[idx].status == .verifying
        else { return }
        all[idx].status = .unreachable
        publish()
    }

    /// Remove entries whose group now exists locally — the fresh
    /// snapshot verified + materialized, so verification is done.
    func resolveMaterialized(_ groupIDHexes: Set<String>) {
        guard !groupIDHexes.isEmpty else { return }
        let before = all.count
        all.removeAll { groupIDHexes.contains($0.groupIDHex) }
        if all.count != before { publish() }
    }

    func removeForOwner(_ id: IdentityID) {
        let before = all.count
        all.removeAll { $0.ownerIdentityID == id }
        if all.count != before { publish() }
    }

    func setCurrentIdentity(_ id: IdentityID?) {
        currentIdentity = id
        publish()
    }

    /// Snapshot of pending verifications for the current identity,
    /// newest first.
    nonisolated var snapshots: AsyncStream<[PendingGroupVerification]> {
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
        continuation: AsyncStream<[PendingGroupVerification]>.Continuation
    ) {
        continuations[id] = continuation
        continuation.yield(filtered())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func filtered() -> [PendingGroupVerification] {
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
