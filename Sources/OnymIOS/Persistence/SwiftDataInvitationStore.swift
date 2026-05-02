import Foundation
import SwiftData

/// SwiftData-backed `@Model` row for a received invitation. Sensitive
/// fields are stored as AES-GCM-wrapped `Data` (via `StorageEncryption`);
/// the queryable fields (`id`, `receivedAt`) stay cleartext so dedup
/// lookups don't need to scan-and-decrypt.
@Model
final class PersistedInvitation {
    @Attribute(.unique) var id: String
    var encryptedPayload: Data
    var receivedAt: Date
    /// Cleartext: enum tag (small enumeration, not user-identifying).
    var statusRaw: String

    init(id: String, encryptedPayload: Data, receivedAt: Date, statusRaw: String) {
        self.id = id
        self.encryptedPayload = encryptedPayload
        self.receivedAt = receivedAt
        self.statusRaw = statusRaw
    }
}

/// SwiftData-backed `InvitationStore`. Owns one `ModelContainer` for
/// the invitation schema; each call hops to a serial actor executor so
/// concurrent saves don't fight over `ModelContext`.
actor SwiftDataInvitationStore: InvitationStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/Invitations.store`, with
    /// `FileProtectionType.complete` on the directory.
    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let storeDir = appSupport.appendingPathComponent("OnymIOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = storeDir.appendingPathComponent("Invitations.store")
        let schema = Schema([PersistedInvitation.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        self.container = container
        self.context = ModelContext(container)
    }

    /// In-memory factory for tests + a runtime fallback when the
    /// on-disk store fails to open. Drops everything on actor
    /// deinit.
    static func inMemory() -> SwiftDataInvitationStore {
        let schema = Schema([PersistedInvitation.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return SwiftDataInvitationStore(container: container)
    }

    private init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - InvitationStore

    func list() -> [IncomingInvitationRecord] {
        let descriptor = FetchDescriptor<PersistedInvitation>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap(Self.decode)
    }

    @discardableResult
    func save(_ record: IncomingInvitationRecord) -> Bool {
        let id = record.id
        let dup = FetchDescriptor<PersistedInvitation>(
            predicate: #Predicate { $0.id == id }
        )
        if let count = try? context.fetchCount(dup), count > 0 { return false }

        guard let encrypted = try? StorageEncryption.encrypt(record.payload) else { return false }
        context.insert(PersistedInvitation(
            id: record.id,
            encryptedPayload: encrypted,
            receivedAt: record.receivedAt,
            statusRaw: record.status.rawValue
        ))
        try? context.save()
        return true
    }

    func updateStatus(id: String, status: IncomingInvitationStatus) {
        let descriptor = FetchDescriptor<PersistedInvitation>(
            predicate: #Predicate { $0.id == id }
        )
        guard let rows = try? context.fetch(descriptor) else { return }
        for row in rows { row.statusRaw = status.rawValue }
        try? context.save()
    }

    func delete(id: String) {
        let descriptor = FetchDescriptor<PersistedInvitation>(
            predicate: #Predicate { $0.id == id }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    // MARK: - Mapping

    private static func decode(_ row: PersistedInvitation) -> IncomingInvitationRecord? {
        guard let payload = try? StorageEncryption.decrypt(row.encryptedPayload) else { return nil }
        let status = IncomingInvitationStatus(rawValue: row.statusRaw) ?? .pending
        return IncomingInvitationRecord(
            id: row.id,
            payload: payload,
            receivedAt: row.receivedAt,
            status: status
        )
    }
}
