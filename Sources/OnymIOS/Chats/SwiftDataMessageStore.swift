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

    func list(groupID: String, ownerIDString: String) -> [ChatMessage] {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate {
                $0.groupID == groupID && $0.ownerIdentityIDString == ownerIDString
            },
            sortBy: [SortDescriptor(\.sentAt, order: .forward)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap(Self.decode)
    }

    func latestMessage(groupID: String, ownerIDString: String) -> ChatMessage? {
        var descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate {
                $0.groupID == groupID && $0.ownerIdentityIDString == ownerIDString
            },
            sortBy: [SortDescriptor(\.sentAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return nil }
        return Self.decode(row)
    }

    func unreadCount(groupID: String, ownerIDString: String, since: Date) -> Int {
        // Plain columns only (direction + sentAt) → no decryption needed.
        let incoming = MessageDirection.incoming.rawValue
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate {
                $0.groupID == groupID
                    && $0.ownerIdentityIDString == ownerIDString
                    && $0.directionRaw == incoming
                    && $0.sentAt > since
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Full-text-ish search across all of one identity's messages, newest
    /// first. Bodies are encrypted at rest, so this decrypts every row
    /// for the owner and filters by a case-insensitive substring match on
    /// the plaintext body — the SQL layer can't see into the ciphertext.
    /// `limit` caps the returned rows so a broad query on a large history
    /// doesn't build an unbounded result list. An empty/whitespace query
    /// returns nothing.
    func search(ownerIDString: String, query: String, limit: Int = 200) -> [ChatMessage] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.ownerIdentityIDString == ownerIDString },
            sortBy: [SortDescriptor(\.sentAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        var results: [ChatMessage] = []
        for row in rows {
            guard let message = Self.decode(row) else { continue }
            if message.body.lowercased().contains(needle) {
                results.append(message)
                if results.count >= limit { break }
            }
        }
        return results
    }

    @discardableResult
    func insertOrUpdate(_ message: ChatMessage) -> Bool {
        guard let encoded = try? Self.encode(message) else { return false }

        let id = message.id.uuidString
        let owner = encoded.ownerIdentityIDString
        // Match on the composite (id, owner): the same fanned-out wire
        // message arriving at a second identity's inbox gets its own
        // row rather than clobbering the first identity's.
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == id && $0.ownerIdentityIDString == owner }
        )
        if let existing = try? context.fetch(descriptor).first {
            // Receive-side replays land here as no-op overwrites; the
            // outgoing pending → sent / failed flip uses the same path.
            existing.groupID = encoded.groupID
            existing.sentAt = encoded.sentAt
            existing.directionRaw = encoded.directionRaw
            existing.statusRaw = encoded.statusRaw
            existing.groupTypeRaw = encoded.groupTypeRaw
            existing.replyToMessageIDString = encoded.replyToMessageIDString
            existing.failureReasonRaw = encoded.failureReasonRaw
            existing.encryptedSenderBlsPubkeyHex = encoded.encryptedSenderBlsPubkeyHex
            existing.encryptedBody = encoded.encryptedBody
            existing.encryptedAttachmentJSON = encoded.encryptedAttachmentJSON
            existing.encryptedVideoAttachmentJSON = encoded.encryptedVideoAttachmentJSON
            existing.encryptedAlbumJSON = encoded.encryptedAlbumJSON
            existing.encryptedVoiceAttachmentJSON = encoded.encryptedVoiceAttachmentJSON
            try? context.save()
            return false
        }

        context.insert(encoded)
        try? context.save()
        return true
    }

    func updateStatus(id: UUID, ownerIDString: String, status: MessageStatus, failureReason: SendFailureReason?) {
        let key = id.uuidString
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == key && $0.ownerIdentityIDString == ownerIDString }
        )
        guard let row = try? context.fetch(descriptor).first else { return }
        row.statusRaw = status.rawValue
        row.failureReasonRaw = failureReason?.rawValue
        try? context.save()
    }

    func delete(id: UUID, ownerIDString: String) {
        let key = id.uuidString
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate { $0.id == key && $0.ownerIdentityIDString == ownerIDString }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    func deleteGroup(groupID: String, ownerIDString: String) {
        let descriptor = FetchDescriptor<PersistedMessage>(
            predicate: #Predicate {
                $0.groupID == groupID && $0.ownerIdentityIDString == ownerIDString
            }
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
        let encryptedAttachment = try message.imageAttachment.map { attachment in
            try StorageEncryption.encrypt(JSONEncoder().encode(attachment))
        }
        let encryptedVideoAttachment = try message.videoAttachment.map { attachment in
            try StorageEncryption.encrypt(JSONEncoder().encode(attachment))
        }
        let encryptedAlbum = try message.albumAttachments.map { album in
            try StorageEncryption.encrypt(JSONEncoder().encode(album))
        }
        let encryptedVoice = try message.voiceAttachment.map { attachment in
            try StorageEncryption.encrypt(JSONEncoder().encode(attachment))
        }
        return PersistedMessage(
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
            encryptedBody: try StorageEncryption.encrypt(message.body),
            encryptedAttachmentJSON: encryptedAttachment,
            encryptedVideoAttachmentJSON: encryptedVideoAttachment,
            encryptedAlbumJSON: encryptedAlbum,
            encryptedVoiceAttachmentJSON: encryptedVoice
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
        // Attachment is advisory: a decrypt/decode miss degrades to a
        // text-only row rather than dropping the whole message.
        let imageAttachment: ChatImageAttachment? = row.encryptedAttachmentJSON
            .flatMap { try? StorageEncryption.decrypt($0) }
            .flatMap { try? JSONDecoder().decode(ChatImageAttachment.self, from: $0) }
        let videoAttachment: ChatVideoAttachment? = row.encryptedVideoAttachmentJSON
            .flatMap { try? StorageEncryption.decrypt($0) }
            .flatMap { try? JSONDecoder().decode(ChatVideoAttachment.self, from: $0) }
        let albumAttachments: [ChatMediaAttachment]? = row.encryptedAlbumJSON
            .flatMap { try? StorageEncryption.decrypt($0) }
            .flatMap { try? JSONDecoder().decode([ChatMediaAttachment].self, from: $0) }
        let voiceAttachment: ChatVoiceAttachment? = row.encryptedVoiceAttachmentJSON
            .flatMap { try? StorageEncryption.decrypt($0) }
            .flatMap { try? JSONDecoder().decode(ChatVoiceAttachment.self, from: $0) }
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
            failureReason: row.failureReasonRaw.flatMap(SendFailureReason.init(rawValue:)),
            imageAttachment: imageAttachment,
            videoAttachment: videoAttachment,
            albumAttachments: albumAttachments,
            voiceAttachment: voiceAttachment
        )
    }
}
