import Foundation
@testable import OnymIOS

/// Reusable in-memory `IntroKeyStore`. Same contract as
/// `KeychainIntroKeyStore` without the Keychain plumbing — fast
/// tests of `InviteIntroducer`, `IntroInboxPump`, and the future
/// request-flow interactors that don't want to touch the Security
/// framework.
actor InMemoryIntroKeyStore: IntroKeyStore {

    private var entries: [IntroKeyEntry] = []
    private let now: @Sendable () -> Date
    /// Per-owner subscriber continuations. Mutations re-emit the
    /// filtered+sorted snapshot to every subscriber whose owner
    /// matches.
    private var continuations: [IdentityID: [UUID: AsyncStream<[IntroKeyEntry]>.Continuation]] = [:]

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func save(_ entry: IntroKeyEntry) async {
        purgeExpired()
        entries.removeAll { $0.introPublicKey == entry.introPublicKey }
        entries.append(entry)
        publish(forOwner: entry.ownerIdentityID)
    }

    func find(introPublicKey: Data) async -> IntroKeyEntry? {
        purgeExpired()
        return entries.first { $0.introPublicKey == introPublicKey }
    }

    func listForOwner(_ ownerIdentityID: IdentityID) async -> [IntroKeyEntry] {
        purgeExpired()
        return snapshotForOwner(ownerIdentityID)
    }

    func revoke(introPublicKey: Data) async {
        let owners = Set(entries.filter { $0.introPublicKey == introPublicKey }.map(\.ownerIdentityID))
        entries.removeAll { $0.introPublicKey == introPublicKey }
        for owner in owners { publish(forOwner: owner) }
    }

    @discardableResult
    func deleteForOwner(_ ownerIdentityID: IdentityID) async -> Int {
        let before = entries.count
        entries.removeAll { $0.ownerIdentityID == ownerIdentityID }
        let removed = before - entries.count
        if removed > 0 { publish(forOwner: ownerIdentityID) }
        return removed
    }

    nonisolated func entriesStream(forOwner ownerIdentityID: IdentityID) -> AsyncStream<[IntroKeyEntry]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(owner: ownerIdentityID, id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(owner: ownerIdentityID, id: id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(
        owner: IdentityID,
        id: UUID,
        continuation: AsyncStream<[IntroKeyEntry]>.Continuation
    ) {
        purgeExpired()
        continuations[owner, default: [:]][id] = continuation
        continuation.yield(snapshotForOwner(owner))
    }

    private func unsubscribe(owner: IdentityID, id: UUID) {
        continuations[owner]?.removeValue(forKey: id)
        if continuations[owner]?.isEmpty == true {
            continuations.removeValue(forKey: owner)
        }
    }

    private func publish(forOwner owner: IdentityID) {
        guard let bucket = continuations[owner] else { return }
        let snapshot = snapshotForOwner(owner)
        for cont in bucket.values { cont.yield(snapshot) }
    }

    private func snapshotForOwner(_ owner: IdentityID) -> [IntroKeyEntry] {
        entries
            .filter { $0.ownerIdentityID == owner }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Drop entries whose `createdAt` is older than
    /// `IntroKeyEntry.lifetime` relative to the injected clock and
    /// re-emit per affected owner so the `IntroInboxPump` reconciler
    /// can cancel relayer subscriptions for expired slots.
    private func purgeExpired() {
        let instant = now()
        let prunedOwners = Set(
            entries.filter { $0.isExpired(at: instant) }.map(\.ownerIdentityID)
        )
        guard !prunedOwners.isEmpty else { return }
        entries.removeAll { $0.isExpired(at: instant) }
        for owner in prunedOwners { publish(forOwner: owner) }
    }
}
