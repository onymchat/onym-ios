import Foundation
import SwiftData

/// SwiftData-backed `GroupStore`. Owns one `ModelContainer` for the
/// group schema; each call hops to this actor's executor so concurrent
/// saves don't fight over `ModelContext`. Same shape as
/// `SwiftDataInvitationStore`.
actor SwiftDataGroupStore: GroupStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/Groups.store`, with
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
        let url = storeDir.appendingPathComponent("Groups.store")
        let schema = Schema([PersistedGroup.self])
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        self.container = container
        self.context = ModelContext(container)
    }

    /// In-memory factory for tests.
    static func inMemory() -> SwiftDataGroupStore {
        let schema = Schema([PersistedGroup.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return SwiftDataGroupStore(container: container)
    }

    private init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - GroupStore

    func list() -> [ChatGroup] {
        let descriptor = FetchDescriptor<PersistedGroup>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        return rows.compactMap(Self.decode)
    }

    @discardableResult
    func insertOrUpdate(_ group: ChatGroup) -> Bool {
        guard let encoded = try? Self.encode(group) else { return false }

        let id = group.id
        let descriptor = FetchDescriptor<PersistedGroup>(
            predicate: #Predicate { $0.id == id }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.epoch = encoded.epoch
            existing.tierRaw = encoded.tierRaw
            existing.groupTypeRaw = encoded.groupTypeRaw
            existing.isPublishedOnChain = encoded.isPublishedOnChain
            existing.encryptedName = encoded.encryptedName
            existing.encryptedGroupSecret = encoded.encryptedGroupSecret
            existing.encryptedMembersJSON = encoded.encryptedMembersJSON
            existing.encryptedSalt = encoded.encryptedSalt
            existing.encryptedCommitment = encoded.encryptedCommitment
            existing.encryptedAdminPubkeyHex = encoded.encryptedAdminPubkeyHex
            try? context.save()
            return false
        }

        context.insert(encoded)
        try? context.save()
        return true
    }

    func markPublished(id: String, commitment: Data?) {
        let descriptor = FetchDescriptor<PersistedGroup>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = try? context.fetch(descriptor).first else { return }
        row.isPublishedOnChain = true
        if let commitment {
            row.encryptedCommitment = (try? StorageEncryption.encrypt(commitment))
                ?? row.encryptedCommitment
        }
        try? context.save()
    }

    func delete(id: String) {
        let descriptor = FetchDescriptor<PersistedGroup>(
            predicate: #Predicate { $0.id == id }
        )
        if let rows = try? context.fetch(descriptor) {
            for row in rows { context.delete(row) }
        }
        try? context.save()
    }

    // MARK: - Mapping

    private static func encode(_ group: ChatGroup) throws -> PersistedGroup {
        let membersJSON = try JSONEncoder().encode(group.members)
        return PersistedGroup(
            id: group.id,
            createdAt: group.createdAt,
            epoch: Int64(bitPattern: group.epoch),
            tierRaw: group.tier.rawValue,
            groupTypeRaw: group.groupType.rawValue,
            isPublishedOnChain: group.isPublishedOnChain,
            encryptedName: try StorageEncryption.encrypt(group.name),
            encryptedGroupSecret: try StorageEncryption.encrypt(group.groupSecret),
            encryptedMembersJSON: try StorageEncryption.encrypt(membersJSON),
            encryptedSalt: try StorageEncryption.encrypt(group.salt),
            encryptedCommitment: try group.commitment.map(StorageEncryption.encrypt),
            encryptedAdminPubkeyHex: try group.adminPubkeyHex.map(StorageEncryption.encrypt)
        )
    }

    private static func decode(_ row: PersistedGroup) -> ChatGroup? {
        guard
            let name = try? StorageEncryption.decryptString(row.encryptedName),
            let groupSecret = try? StorageEncryption.decrypt(row.encryptedGroupSecret),
            let membersJSON = try? StorageEncryption.decrypt(row.encryptedMembersJSON),
            let members = try? JSONDecoder().decode([GovernanceMember].self, from: membersJSON),
            let salt = try? StorageEncryption.decrypt(row.encryptedSalt),
            let tier = SEPTier(rawValue: row.tierRaw),
            let groupType = SEPGroupType(rawValue: row.groupTypeRaw)
        else {
            return nil
        }
        let commitment = row.encryptedCommitment.flatMap { try? StorageEncryption.decrypt($0) }
        let adminPubkeyHex = row.encryptedAdminPubkeyHex.flatMap {
            try? StorageEncryption.decryptString($0)
        }
        return ChatGroup(
            id: row.id,
            name: name,
            groupSecret: groupSecret,
            createdAt: row.createdAt,
            members: members,
            epoch: UInt64(bitPattern: row.epoch),
            salt: salt,
            commitment: commitment,
            tier: tier,
            groupType: groupType,
            adminPubkeyHex: adminPubkeyHex,
            isPublishedOnChain: row.isPublishedOnChain
        )
    }
}
