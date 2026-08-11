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

    @discardableResult
    public func record(_ request: IntroRequest) async -> Bool {
        // Dedup on the Nostr event id. Every relay reconnect replays the
        // inbox, so this is the common path, not the edge case.
        let id = request.id
        let existing = FetchDescriptor<PersistedIntroRequest>(
            predicate: #Predicate { $0.id == id }
        )
        if let found = try? context.fetchCount(existing), found > 0 { return false }

        guard let row = try? Self.encode(request) else { return false }
        context.insert(row)
        guard (try? context.save()) != nil else { return false }
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

    /// Newest-first, matching `InMemoryIntroRequestStore.current()`.
    /// Rows that fail to decrypt are skipped rather than failing the
    /// whole read — a single corrupted row shouldn't hide every other
    /// pending request.
    private func loadAll() -> [IntroRequest] {
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
