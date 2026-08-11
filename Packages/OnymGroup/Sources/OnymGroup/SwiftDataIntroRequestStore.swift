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

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/IntroRequests.store` with
    /// `FileProtectionType.complete`. Schema mismatch wipes and retries
    /// once, matching the policy on the message + group stores (pre-1.0
    /// install base; a dropped pending request is recoverable by the
    /// joiner re-sharing).
    public init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let storeDir = appSupport.appendingPathComponent("OnymIOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = storeDir.appendingPathComponent("IntroRequests.store")
        let schema = Schema([PersistedIntroRequest.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(
                    at: url.deletingPathExtension().appendingPathExtension("store\(suffix)")
                )
            }
            try? FileManager.default.removeItem(at: url)
            container = try ModelContainer(for: schema, configurations: [config])
        }
        self.container = container
        self.context = ModelContext(container)
    }

    /// In-memory factory for tests.
    public static func inMemory() -> SwiftDataIntroRequestStore {
        let schema = Schema([PersistedIntroRequest.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return SwiftDataIntroRequestStore(container: container)
    }

    private init(container: ModelContainer) {
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
        // No sweep here: the `publish()` below reads through `loadAll()`,
        // which prunes. Calling it on entry too meant two fetch+delete
        // passes per insert.
        let id = request.id
        let existing = FetchDescriptor<PersistedIntroRequest>(
            predicate: #Predicate { $0.id == id }
        )
        if let found = try? context.fetchCount(existing), found > 0 { return false }

        guard let row = try? Self.encode(request) else { return false }
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
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        try? context.save()
        publish()
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
    private func pruneExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let descriptor = FetchDescriptor<PersistedIntroRequest>(
            predicate: #Predicate { $0.receivedAt < cutoff }
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
    private func loadAll() -> [IntroRequest] {
        pruneExpired()
        let descriptor = FetchDescriptor<PersistedIntroRequest>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap(Self.decode)
    }

    // MARK: - Mapping

    private static func encode(_ request: IntroRequest) throws -> PersistedIntroRequest {
        PersistedIntroRequest(
            id: request.id,
            receivedAt: request.receivedAt,
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
