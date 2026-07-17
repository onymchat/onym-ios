import Foundation
import SwiftData

/// SwiftData-backed `MessageStore`. Owns one `ModelContainer` for the
/// message schema; each call hops to this actor's executor so
/// concurrent writes don't fight over `ModelContext`. Same shape as
/// `SwiftDataGroupStore`.
///
/// Schema lives in a separate `.store` file from groups —
/// `Messages.store` next to `Groups.store` under
/// `Application Support/OnymIOS/`. Separate containers keep schema
/// migrations for one domain from triggering a wipe of the other.
actor SwiftDataMessageStore: MessageStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/Messages.store`, with
    /// `FileProtectionType.complete` on the directory.
    ///
    /// Schema-mismatch at `ModelContainer(...)` init wipes the
    /// on-disk store and retries once. Pre-1.0 install base, no real
    /// users to preserve — matches the policy on `SwiftDataGroupStore`.
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
        let url = storeDir.appendingPathComponent("Messages.store")
        let schema = Schema([PersistedMessage.self])
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
    static func inMemory() -> SwiftDataMessageStore {
        let schema = Schema([PersistedMessage.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return SwiftDataMessageStore(container: container)
    }

    private init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - MessageStore

    func list(groupID: String) -> [ChatMessage] {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.groupID == groupID },
            sortBy: [SortDescriptor(\.sentAt, order: .forward)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap(Self.decode)
    }

    @discardableResult
    func insertOrUpdate(_ message: ChatMessage) -> Bool {
        guard let encoded = try? Self.encode(message) else { return false }

        let id = message.id.uuidString
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == id }
        )
        if let existing = try? context.fetch(descriptor).first {
            // Receive-side replays land here as no-op overwrites; the
            // outgoing pending → sent / failed flip uses the same path.
            existing.groupID = encoded.groupID
            existing.ownerIdentityIDString = encoded.ownerIdentityIDString
            existing.sentAt = encoded.sentAt
            existing.directionRaw = encoded.directionRaw
            existing.statusRaw = encoded.statusRaw
            existing.groupTypeRaw = encoded.groupTypeRaw
            existing.replyToMessageIDString = encoded.replyToMessageIDString
            existing.failureReasonRaw = encoded.failureReasonRaw
            existing.encryptedSenderBlsPubkeyHex = encoded.encryptedSenderBlsPubkeyHex
            existing.encryptedBody = encoded.encryptedBody
            try? context.save()
            return false
        }

        context.insert(encoded)
        try? context.save()
        return true
    }

    func updateStatus(id: UUID, status: MessageStatus, failureReason: SendFailureReason?) {
        let key = id.uuidString
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == key }
        )
        guard let row = try? context.fetch(descriptor).first else { return }
        row.statusRaw = status.rawValue
        row.failureReasonRaw = failureReason?.rawValue
        try? context.save()
    }

    func delete(id: UUID) {
        let key = id.uuidString
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == key }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    func deleteGroup(groupID: String) {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.groupID == groupID }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    func deleteOwner(_ ownerIDString: String) {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.ownerIdentityIDString == ownerIDString }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    // MARK: - Mapping

    private static func encode(_ message: ChatMessage) throws -> PersistedMessage {
        PersistedMessage(
            id: message.id.uuidString,
            groupID: message.groupID,
            ownerIdentityIDString: message.ownerIdentityID.rawValue.uuidString,
            sentAt: message.sentAt,
            directionRaw: message.direction.rawValue,
            statusRaw: message.status.rawValue,
            groupTypeRaw: message.groupType.rawValue,
            replyToMessageIDString: message.replyToMessageID?.uuidString,
            failureReasonRaw: message.failureReason?.rawValue,
            encryptedSenderBlsPubkeyHex: try StorageEncryption.encrypt(message.senderBlsPubkeyHex),
            encryptedBody: try StorageEncryption.encrypt(message.body)
        )
    }

    private static func decode(_ row: PersistedMessage) -> ChatMessage? {
        guard
            let id = UUID(uuidString: row.id),
            let owner = IdentityID(row.ownerIdentityIDString),
            let direction = MessageDirection(rawValue: row.directionRaw),
            let status = MessageStatus(rawValue: row.statusRaw),
            let groupType = SEPGroupType(rawValue: row.groupTypeRaw),
            let senderHex = try? StorageEncryption.decryptString(row.encryptedSenderBlsPubkeyHex),
            let body = try? StorageEncryption.decryptString(row.encryptedBody)
        else {
            return nil
        }
        return ChatMessage(
            id: id,
            groupID: row.groupID,
            ownerIdentityID: owner,
            senderBlsPubkeyHex: senderHex,
            body: body,
            sentAt: row.sentAt,
            direction: direction,
            status: status,
            replyToMessageID: row.replyToMessageIDString.flatMap(UUID.init(uuidString:)),
            groupType: groupType,
            failureReason: row.failureReasonRaw.flatMap(SendFailureReason.init(rawValue:))
        )
    }
}
