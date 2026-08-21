import Foundation
import SwiftData
import OnymFoundation
import OnymIdentity

/// On-disk `PendingChatStore`, in its own `PendingChats.store` file so a
/// schema migration here can't take messages or groups with it.
///
/// ## Why this is persisted
///
/// The offer half could have stayed in memory — a pushed offer is a
/// retained Nostr event the inbox fan-out re-delivers on every launch,
/// which is why `PendingInvitesStore` was process-lifetime. The *asking*
/// half cannot. When a link or QR join stopped opening a sheet and
/// started leaving a row in the chats list, that row became the only
/// evidence the user ever asked, and nothing replays it: the request
/// went out, the founder may take days, and a force-quit in between
/// would leave a person waiting on something their device has no record
/// of.
///
/// No retention sweep, deliberately. `SwiftDataIntroRequestStore` prunes
/// because the founder accumulates strangers' requests; here the rows
/// are the user's own and there are a handful at most. They are cleared
/// when the group materializes, when the identity is removed, or when
/// the user swipes the row away.
public actor SwiftDataPendingChatStore: PendingChatStore {
    private let container: ModelContainer
    private let context: ModelContext

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/PendingChats.store` with
    /// `FileProtectionType.complete`. Open failures go through
    /// `PersistentStoreOpener`: logged, moved aside as `.bak` (never
    /// deleted), retried once.
    public init() throws {
        let url = try PersistentStoreOpener.storeDirectory()
            .appendingPathComponent("PendingChats.store")
        let container = try PersistentStoreOpener.openContainer(
            schema: Schema([PersistedPendingChat.self]),
            url: url
        )
        self.container = container
        self.context = ModelContext(container)
    }

    /// In-memory factory for tests.
    public static func inMemory() -> SwiftDataPendingChatStore {
        let schema = Schema([PersistedPendingChat.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return SwiftDataPendingChatStore(container: container)
    }

    /// A second store over the same container — a relaunch, modelled.
    /// Durability is the reason this store exists at all, so a test has
    /// to be able to close the context and read the rows back through a
    /// fresh one rather than trust the cache it just wrote.
    public func reopened() -> SwiftDataPendingChatStore {
        SwiftDataPendingChatStore(container: container)
    }

    private init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - PendingChatStore

    @discardableResult
    public func insert(_ chat: PendingChat) async -> PendingChatWriteOutcome {
        let id = chat.id
        let existing = FetchDescriptor<PersistedPendingChat>(
            predicate: #Predicate { $0.id == id }
        )
        if let found = try? context.fetch(existing), !found.isEmpty {
            return .alreadyPresent
        }
        guard let row = try? Self.encode(chat) else { return .failed }
        context.insert(row)
        do {
            try context.save()
        } catch {
            // Roll the orphaned in-memory insert back out, or a later
            // save would commit a row that never published — same
            // handling as `SwiftDataIntroRequestStore.record`.
            context.delete(row)
            return .failed
        }
        return .inserted
    }

    public func setStatus(id: String, status: PendingChat.Status) async {
        let descriptor = FetchDescriptor<PersistedPendingChat>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = (try? context.fetch(descriptor))?.first else { return }
        row.statusRaw = Self.raw(status)
        row.failureRaw = Self.failure(status)?.rawValue
        try? context.save()
    }

    public func refreshOffer(
        id: String,
        introPublicKey: Data,
        groupName: String?,
        inviterAlias: String,
        invitationMessage: String?
    ) async {
        let descriptor = FetchDescriptor<PersistedPendingChat>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = (try? context.fetch(descriptor))?.first else { return }
        guard
            let key = try? StorageEncryption.encrypt(introPublicKey),
            let alias = try? StorageEncryption.encrypt(inviterAlias)
        else { return }
        row.encryptedIntroPublicKey = key
        row.encryptedInviterAlias = alias
        row.encryptedGroupName = try? groupName.map(StorageEncryption.encrypt)
        row.encryptedInvitationMessage = try? invitationMessage.map(StorageEncryption.encrypt)
        try? context.save()
    }

    public func delete(id: String) async {
        let descriptor = FetchDescriptor<PersistedPendingChat>(
            predicate: #Predicate { $0.id == id }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        try? context.save()
    }

    public func deleteForIDs(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        // Fetched unfiltered and matched in Swift: `#Predicate` can't
        // close over a Set, and the table holds a handful of rows.
        guard let rows = try? context.fetch(FetchDescriptor<PersistedPendingChat>())
        else { return }
        let stale = rows.filter { ids.contains($0.id) }
        guard !stale.isEmpty else { return }
        for row in stale { context.delete(row) }
        try? context.save()
    }

    public func deleteOwner(_ ownerIDString: String) async {
        let descriptor = FetchDescriptor<PersistedPendingChat>(
            predicate: #Predicate { $0.ownerIdentityIDString == ownerIDString }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        try? context.save()
    }

    public func list() async -> [PendingChat] {
        let descriptor = FetchDescriptor<PersistedPendingChat>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        guard let rows = try? context.fetch(descriptor) else { return [] }
        // A row that won't decrypt is skipped rather than failing the
        // whole read — one corrupted row shouldn't hide every other
        // chat the user is waiting on.
        return rows.compactMap(Self.decode)
    }

    // MARK: - Mapping

    private static func raw(_ status: PendingChat.Status) -> String {
        switch status {
        case .offered:   "offered"
        case .requested: "requested"
        case .failed:    "failed"
        }
    }

    private static func failure(_ status: PendingChat.Status) -> PendingChat.SendFailure? {
        if case .failed(let failure) = status { return failure }
        return nil
    }

    private static func status(raw: String, failure: String?) -> PendingChat.Status {
        switch raw {
        case "requested": .requested
        // A failure whose code didn't survive is still a failure, and
        // the transport one is both the likelier and the safer guess:
        // it says "your request didn't go out", which is true of the
        // other case too.
        case "failed":    .failed(failure.flatMap(PendingChat.SendFailure.init(rawValue:)) ?? .transport)
        default:          .offered
        }
    }

    private static func encode(_ chat: PendingChat) throws -> PersistedPendingChat {
        PersistedPendingChat(
            id: chat.id,
            ownerIdentityIDString: chat.ownerIdentityID.rawValue.uuidString,
            groupIDHex: chat.groupIDHex,
            receivedAt: chat.receivedAt,
            statusRaw: raw(chat.status),
            failureRaw: failure(chat.status)?.rawValue,
            encryptedIntroPublicKey: try StorageEncryption.encrypt(chat.introPublicKey),
            encryptedGroupName: try chat.groupName.map(StorageEncryption.encrypt),
            encryptedInviterAlias: try StorageEncryption.encrypt(chat.inviterAlias),
            encryptedInvitationMessage: try chat.invitationMessage.map(StorageEncryption.encrypt)
        )
    }

    /// Only two fields can take the row down with them: the intro key,
    /// without which Accept has nowhere to reply, and the owner, without
    /// which the row belongs to nobody.
    ///
    /// Everything else degrades. The alias and the group name are
    /// cosmetic, and dropping the row over them would delete from view
    /// the one piece of evidence that this person ever asked to join —
    /// which is the whole argument for persisting these rows at all.
    private static func decode(_ row: PersistedPendingChat) -> PendingChat? {
        guard
            let introPublicKey = try? StorageEncryption.decrypt(row.encryptedIntroPublicKey),
            let owner = UUID(uuidString: row.ownerIdentityIDString)
        else { return nil }
        return PendingChat(
            groupID: PendingChat.bytes(fromHex: row.groupIDHex),
            ownerIdentityID: IdentityID(owner),
            introPublicKey: introPublicKey,
            groupName: row.encryptedGroupName.flatMap { try? StorageEncryption.decryptString($0) },
            inviterAlias: (try? StorageEncryption.decryptString(row.encryptedInviterAlias)) ?? "",
            invitationMessage: row.encryptedInvitationMessage
                .flatMap { try? StorageEncryption.decryptString($0) },
            receivedAt: row.receivedAt,
            status: status(raw: row.statusRaw, failure: row.failureRaw)
        )
    }
}
