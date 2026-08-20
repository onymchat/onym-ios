import Foundation
import SwiftData
import OnymFoundation
import OnymIdentity

/// SwiftData-backed `@Model` row for a received invitation. Sensitive
/// fields are stored as AES-GCM-wrapped `Data` (via `StorageEncryption`);
/// the queryable fields (`id`, `receivedAt`) stay cleartext so dedup
/// lookups don't need to scan-and-decrypt.
@Model
final class PersistedInvitation {
    @Attribute(.unique) var id: String
    /// UUID string of the identity this envelope was delivered to.
    /// Plain (not encrypted) so SwiftData `#Predicate` can filter on
    /// it. Owner IDs are random per-device UUIDs — nothing to leak.
    var ownerIdentityIDString: String
    var encryptedPayload: Data
    var receivedAt: Date
    /// Cleartext: enum tag (small enumeration, not user-identifying).
    var statusRaw: String

    init(
        id: String,
        ownerIdentityIDString: String,
        encryptedPayload: Data,
        receivedAt: Date,
        statusRaw: String
    ) {
        self.id = id
        self.ownerIdentityIDString = ownerIdentityIDString
        self.encryptedPayload = encryptedPayload
        self.receivedAt = receivedAt
        self.statusRaw = statusRaw
    }
}

/// SwiftData-backed `InvitationStore`. Owns one `ModelContainer` for
/// the invitation schema; each call hops to a serial actor executor so
/// concurrent saves don't fight over `ModelContext`.
public actor SwiftDataInvitationStore: InvitationStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/Invitations.store`, with
    /// `FileProtectionType.complete` on the directory.
    ///
    /// Open failures go through `PersistentStoreOpener`: logged,
    /// moved aside as `.bak` (never deleted), retried once — and left
    /// completely untouched when the file is merely unreadable
    /// (locked-device launch).
    public init() throws {
        let url = try PersistentStoreOpener.storeDirectory()
            .appendingPathComponent("Invitations.store")
        let container = try PersistentStoreOpener.openContainer(
            schema: Schema([PersistedInvitation.self]),
            url: url
        )
        self.container = container
        self.context = ModelContext(container)
    }

    /// In-memory factory for tests + a runtime fallback when the
    /// on-disk store fails to open. Drops everything on actor
    /// deinit.
    public static func inMemory() -> SwiftDataInvitationStore {
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

    public func list() -> [IncomingInvitationRecord] {
        let descriptor = FetchDescriptor<PersistedInvitation>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap(Self.decode)
    }

    @discardableResult
    public func save(_ record: IncomingInvitationRecord) -> InvitationSaveOutcome {
        let id = record.id
        let dup = FetchDescriptor<PersistedInvitation>(
            predicate: #Predicate { $0.id == id }
        )
        // Row already here, left exactly as it was — not a write that
        // failed, and no longer spelled like one.
        if let count = try? context.fetchCount(dup), count > 0 { return .duplicate }

        guard let encrypted = try? StorageEncryption.encrypt(record.payload) else { return .failed }
        context.insert(PersistedInvitation(
            id: record.id,
            ownerIdentityIDString: record.ownerIdentityID.rawValue.uuidString,
            encryptedPayload: encrypted,
            receivedAt: record.receivedAt,
            statusRaw: record.status.rawValue
        ))
        try? context.save()
        return .saved
    }

    public func updateStatus(id: String, status: IncomingInvitationStatus) {
        let descriptor = FetchDescriptor<PersistedInvitation>(
            predicate: #Predicate { $0.id == id }
        )
        guard let rows = try? context.fetch(descriptor) else { return }
        for row in rows { row.statusRaw = status.rawValue }
        try? context.save()
    }

    public func delete(id: String) {
        let descriptor = FetchDescriptor<PersistedInvitation>(
            predicate: #Predicate { $0.id == id }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    public func deleteOwner(_ ownerIDString: String) {
        let descriptor = FetchDescriptor<PersistedInvitation>(
            predicate: #Predicate { $0.ownerIdentityIDString == ownerIDString }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    // MARK: - Mapping

    private static func decode(_ row: PersistedInvitation) -> IncomingInvitationRecord? {
        guard let owner = IdentityID(row.ownerIdentityIDString),
              let payload = try? StorageEncryption.decrypt(row.encryptedPayload)
        else { return nil }
        let status = IncomingInvitationStatus(rawValue: row.statusRaw) ?? .pending
        return IncomingInvitationRecord(
            id: row.id,
            ownerIdentityID: owner,
            payload: payload,
            receivedAt: row.receivedAt,
            status: status
        )
    }
}
