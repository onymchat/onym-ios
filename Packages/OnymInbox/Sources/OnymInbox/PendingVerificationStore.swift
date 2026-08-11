import Foundation
import OnymIdentity

/// A Tyranny group whose invitation snapshot couldn't be verified at an
/// exact epoch (the chain had advanced past it), so it's awaiting a
/// fresh snapshot from the admin before it may materialize. Kept OUT of
/// the chats list — an unverifiable snapshot must never look like a real
/// chat — and surfaced in the Invitations UI so the user knows a join is
/// in flight (or stuck because the admin is offline).
public struct PendingGroupVerification: Identifiable, Equatable, Sendable {
    public enum Status: Sendable, Equatable {
        /// Refresh request sent; waiting for the admin's reply.
        case verifying
        /// No reply within the timeout (or no admin inbox to ask) —
        /// surfaced to the user with a Retry.
        case unreachable
        /// This device couldn't read the chain: no relayer, no contract
        /// binding for the active network, or the relayer refused.
        ///
        /// Distinct from `unreachable` because the remedy is the user's
        /// own settings, not the admin's availability. These were the
        /// same state until it turned out that the most common way to
        /// get "the admin is offline" was a receiver that had never
        /// resolved a contract binding — a message that named the wrong
        /// party and offered a Retry that could not possibly work.
        case chainUnreachable
        /// This device has no relayer endpoint or no contract binding
        /// for the active network yet.
        ///
        /// Usually not a misconfiguration but a race: both lists are
        /// fetched from GitHub in the background at launch, so a device
        /// that was offline for those few seconds has nothing to call
        /// and nothing to call it on. Separated from `chainUnreachable`
        /// because "we're still setting up, try again" and "your network
        /// or settings are wrong" ask the user for different things.
        case chainNotConfigured
        /// The group's own anchoring transaction hasn't settled yet, or
        /// our read is lagging one that has. Resolves on its own within
        /// seconds; the Retry here re-reads the chain.
        case chainSettling
    }

    /// Dedupe key — one pending verification per group.
    public var id: String { groupIDHex }
    public let groupIDHex: String
    public let ownerIdentityID: IdentityID
    public let groupName: String
    public var status: Status
    public let receivedAt: Date
}

/// In-memory, per-identity-filtered store of groups awaiting
/// verification. In-memory by design: the stale invitation is a retained
/// Nostr event re-delivered on every launch, so the verifier re-defers
/// and re-requests on relaunch — same model as `PendingInvitesStore`.
public actor PendingVerificationStore {
    private var all: [PendingGroupVerification] = []
    private var currentIdentity: IdentityID?
    private var continuations: [UUID: AsyncStream<[PendingGroupVerification]>.Continuation] = [:]

    public init() {}

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

    public func contains(groupIDHex: String) -> Bool {
        all.contains { $0.groupIDHex == groupIDHex }
    }

    public func status(groupIDHex: String) -> PendingGroupVerification.Status? {
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

    public func removeForOwner(_ id: IdentityID) {
        let before = all.count
        all.removeAll { $0.ownerIdentityID == id }
        if all.count != before { publish() }
    }

    public func setCurrentIdentity(_ id: IdentityID?) {
        currentIdentity = id
        publish()
    }

    /// Snapshot of pending verifications for the current identity,
    /// newest first.
    public nonisolated var snapshots: AsyncStream<[PendingGroupVerification]> {
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
