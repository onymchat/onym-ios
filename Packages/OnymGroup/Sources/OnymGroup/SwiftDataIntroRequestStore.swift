import Foundation
import SwiftData
import OnymFoundation

/// On-disk `IntroRequestStore`. Same actor + container shape as
/// `SwiftDataMessageStore`, in its own `IntroRequests.store` file so a
/// schema migration here can't wipe messages or groups.
///
/// ## Why this is persisted
///
/// `InMemoryIntroRequestStore` was deliberately process-lifetime: the
/// approval UI was a modal the admin was expected to act on there and
/// then, and a lost request just meant the joiner re-shared. Now that
/// the request renders as a row *inside the chat thread*, disappearing
/// on force-quit reads as a message the app lost. The joiner has no way
/// to know their request evaporated — they're sitting on "Waiting for
/// the host to approve…" — so durability moved from nice-to-have to
/// correctness.
///
/// The matching intro *private* keys already persist
/// (`KeychainIntroKeyStore`), so a request restored here is still
/// decryptable after a relaunch — `JoinRequestApprover.start()` re-runs
/// its decode over the restored snapshot on subscribe.
public actor SwiftDataIntroRequestStore: IntroRequestStore {
    private let container: ModelContainer
    private let context: ModelContext

    private var continuations: [UUID: AsyncStream<[IntroRequest]>.Continuation] = [:]

    /// Event ids already acted on, mirrored from `handledLog` so the
    /// hot `record` path doesn't hit storage per inbound.
    private var consumed: Set<String>
    /// Durable half of the tombstone. Deleting the pending row is not
    /// enough now that links are multi-use: the subscription outlives
    /// the approval and the REQ carries no `since`, so every reconnect
    /// replays a handled request and would re-insert it here.
    private let handledLog: any HandledIntroRequestLog

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/IntroRequests.store` with
    /// `FileProtectionType.complete`. Open failures go through
    /// `PersistentStoreOpener`: logged, moved aside as `.bak` (never
    /// deleted), retried once — and left completely untouched when
    /// the file is merely unreadable (locked-device launch).
    public init(
        handledLog: any HandledIntroRequestLog = UserDefaultsHandledIntroRequestLog()
    ) throws {
        self.handledLog = handledLog
        self.consumed = handledLog.handledIDs()
        let url = try PersistentStoreOpener.storeDirectory()
            .appendingPathComponent("IntroRequests.store")
        let container = try PersistentStoreOpener.openContainer(
            schema: Schema([PersistedIntroRequest.self]),
            url: url
        )
        self.container = container
        self.context = ModelContext(container)
    }

    /// In-memory factory for tests. `handledLog` is injectable so a
    /// test can share one across two stores and model a relaunch —
    /// the tombstones are the half that is meant to outlive the rows.
    public static func inMemory(
        handledLog: any HandledIntroRequestLog = InMemoryHandledIntroRequestLog()
    ) -> SwiftDataIntroRequestStore {
        let schema = Schema([PersistedIntroRequest.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return SwiftDataIntroRequestStore(container: container, handledLog: handledLog)
    }

    private init(
        container: ModelContainer,
        handledLog: any HandledIntroRequestLog = InMemoryHandledIntroRequestLog()
    ) {
        self.handledLog = handledLog
        self.consumed = handledLog.handledIDs()
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - IntroRequestStore

    /// Returns `true` when a new row was written. `false` covers both
    /// "already present" (the common case — relays replay the inbox on
    /// every reconnect) and "couldn't be written", matching the
    /// protocol's `Bool` contract; the sole caller
    /// (`IntroInboxPump`) discards the result either way, and the two
    /// cases call for the same thing from it — nothing.
    @discardableResult
    public func record(_ request: IntroRequest) async -> Bool {
        // Already acted on: a replay of an approved/declined request
        // must not reappear as pending.
        if consumed.contains(request.id) { return false }
        // No sweep here: the `publish()` below reads through `loadAll()`,
        // which prunes. Calling it on entry too meant two fetch+delete
        // passes per insert.
        let id = request.id
        let existing = FetchDescriptor<PersistedIntroRequest>(
            predicate: #Predicate { $0.id == id }
        )
        if let found = try? context.fetch(existing), let row = found.first {
            // Backfill a row written before `firstSeenAt` existed. Its
            // clock starts now rather than at some sender-asserted past,
            // so a migrated request gets a full window instead of being
            // swept on the next read.
            if row.firstSeenAt == nil {
                row.firstSeenAt = Date()
                try? context.save()
            }
            return false
        }

        guard let row = try? Self.encode(request, firstSeenAt: Date()) else { return false }
        context.insert(row)
        do {
            try context.save()
        } catch {
            // Roll the orphaned in-memory insert back out. Without this
            // the half-inserted object survives in the context and a
            // later `consume()`'s `save()` would commit it — a row that
            // never published, appearing from nowhere on the next read.
            // Same handling as `SwiftDataMessageStore.insertOrUpdate`.
            context.delete(row)
            return false
        }
        publish()
        return true
    }

    public func consume(id: String) async {
        let descriptor = FetchDescriptor<PersistedIntroRequest>(
            predicate: #Predicate { $0.id == id }
        )
        // Unconditional, so a tombstone can be laid ahead of a replay
        // that hasn't landed yet.
        consumed.insert(id)
        let rows = (try? context.fetch(descriptor)) ?? []
        // Attribute to the link it arrived on so `pruneTombstones` can
        // drop it when that link is retired.
        // Durable even when the row is absent (a tombstone laid ahead
        // of a replay, or a stale sibling id). Without the row there is
        // no link to attribute it to, so it goes in unattributed: it can
        // never be pruned by a retired link, and is bounded only by the
        // log's own cap — the right trade, since losing it means the
        // handled request comes back as pending on the next cold start.
        let introPub = rows.first.flatMap { Self.decode($0)?.targetIntroPublicKey }
        handledLog.record(
            id: id,
            introPublicKey: introPub ?? InMemoryIntroRequestStore.unattributedLink
        )
        guard !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        try? context.save()
        publish()
    }

    public func pruneTombstones(retiring retiredPublicKeys: Set<Data>) async {
        handledLog.prune(retiring: retiredPublicKeys)
        consumed = handledLog.handledIDs()
    }

    public func current() async -> [IntroRequest] {
        loadAll()
    }

    public nonisolated var requests: AsyncStream<[IntroRequest]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(id: UUID, continuation: AsyncStream<[IntroRequest]>.Continuation) {
        continuations[id] = continuation
        // Replay what's on disk immediately so a cold launch renders the
        // restored requests without waiting for a fresh relay delivery.
        continuation.yield(loadAll())
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        let snap = loadAll()
        for cont in continuations.values { cont.yield(snap) }
    }

    /// How long an unanswered request is kept before it's dropped.
    ///
    /// Persistence closed the "force-quit loses the request" hole, but it
    /// opened a slower one: nothing else deletes these rows. A request
    /// is only `consume`d when the founder acts on it, and there are
    /// paths where that never happens — the founder deletes the group
    /// locally while its invite link is still live (the request keeps
    /// arriving for a group that no longer exists, so no thread can
    /// render it), or an approve fails permanently at the transport leg
    /// and is never retried. Before persistence, process death swept
    /// those up. This is what replaces it.
    ///
    /// A week is well past the point where a joiner staring at "Waiting
    /// for the host to approve…" has given up and re-shared, and the
    /// intro key stays valid until revoked, so an expired request costs
    /// the joiner one more tap rather than locking them out.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// Drop requests older than `retention`. Called on the read and
    /// write paths rather than on a timer: the store is only interesting
    /// while the app is running, and a sweep here is a single indexed
    /// delete over a table that holds a handful of rows.
    ///
    /// Measured on `firstSeenAt` — this device's own clock — and never
    /// on `receivedAt`, which the joiner asserts in the event's `ms`
    /// tag. On `receivedAt`, a founder who was offline longer than the
    /// window would have every replayed request swept the moment the app
    /// read the store, and a joiner stamping a far-future `ms` would get
    /// a row that outlived every sweep.
    ///
    /// Rows written before `firstSeenAt` existed have nil and are left
    /// alone; `record` backfills them, so they age from first sight
    /// rather than being swept on the migration read.
    /// `now` is injectable so tests can advance the clock rather than
    /// fabricate a `firstSeenAt` the production path would never write.
    func pruneExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let descriptor = FetchDescriptor<PersistedIntroRequest>(
            predicate: #Predicate { row in
                if let firstSeen = row.firstSeenAt { firstSeen < cutoff } else { false }
            }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }
        for row in stale { context.delete(row) }
        try? context.save()

        // Tell subscribers. A sweep triggered by a plain `current()` read
        // used to delete the row and leave it on screen until some
        // unrelated `record`/`consume` happened to publish — the founder
        // would be looking at a request that no longer exists.
        //
        // `publish()` calls `loadAll()`, which calls back into here, so
        // the flag breaks the recursion: the nested sweep finds nothing
        // to delete anyway, but relying on that would make this correct
        // by accident.
        guard !isPruning else { return }
        isPruning = true
        defer { isPruning = false }
        publish()
    }

    /// Guards `pruneExpired` → `publish` → `loadAll` → `pruneExpired`.
    private var isPruning = false

    /// Newest-first, matching `InMemoryIntroRequestStore.current()`.
    /// Rows that fail to decrypt are skipped rather than failing the
    /// whole read — a single corrupted row shouldn't hide every other
    /// pending request.
    /// Tombstoned ids are filtered here as well as in `record`: the
    /// tombstone is written before the row is deleted, so a crash in
    /// that window leaves a handled request on disk. Filtering on read
    /// makes the two halves self-healing instead of resurrecting it.
    private func loadAll() -> [IntroRequest] {
        pruneExpired()
        let descriptor = FetchDescriptor<PersistedIntroRequest>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap(Self.decode).filter { !consumed.contains($0.id) }
    }

    // MARK: - Mapping

    private static func encode(
        _ request: IntroRequest,
        firstSeenAt: Date
    ) throws -> PersistedIntroRequest {
        PersistedIntroRequest(
            id: request.id,
            receivedAt: request.receivedAt,
            firstSeenAt: firstSeenAt,
            encryptedTargetIntroPublicKey: try StorageEncryption.encrypt(
                request.targetIntroPublicKey
            ),
            encryptedPayload: try StorageEncryption.encrypt(request.payload)
        )
    }

    private static func decode(_ row: PersistedIntroRequest) -> IntroRequest? {
        guard
            let introPub = try? StorageEncryption.decrypt(row.encryptedTargetIntroPublicKey),
            let payload = try? StorageEncryption.decrypt(row.encryptedPayload)
        else {
            return nil
        }
        return IntroRequest(
            id: row.id,
            targetIntroPublicKey: introPub,
            payload: payload,
            receivedAt: row.receivedAt
        )
    }
}
