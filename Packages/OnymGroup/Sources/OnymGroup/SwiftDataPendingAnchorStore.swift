import Foundation
import SwiftData
import OnymFoundation
import OnymIdentity

/// On-disk `PendingAnchorStore`. Same actor + container shape as
/// `SwiftDataIntroRequestStore`, in its own `PendingAnchors.store` file
/// so a schema migration here can't wipe groups or requests.
///
/// The ordering is the whole design: `record` returns only once the row
/// is saved, because the caller submits the transaction on the next
/// line. A store that batched, cached or saved lazily would leave
/// exactly the gap this is here to close — the process dying, or the
/// answer never arriving, between the submit and the write.
///
/// A failure to save is not swallowed. Carrying on would submit a
/// transaction whose salt nothing can recover, which is the state the
/// whole mechanism exists to make unreachable; the caller turns the
/// throw into a refusal the founder can act on instead.
public actor SwiftDataPendingAnchorStore: PendingAnchorStore {
    private let container: ModelContainer
    private let context: ModelContext

    enum StoreError: Error {
        /// The row could not be saved, so the salt would not survive
        /// the submit that was about to follow it.
        case couldNotRecord(String)
    }

    /// Production initializer — on-disk SQLite under
    /// `Application Support/OnymIOS/PendingAnchors.store` with
    /// `FileProtectionType.complete`. Open failures go through
    /// `PersistentStoreOpener`: logged, moved aside as `.bak` (never
    /// deleted), retried once.
    public init() throws {
        let url = try PersistentStoreOpener.storeDirectory()
            .appendingPathComponent("PendingAnchors.store")
        let container = try PersistentStoreOpener.openContainer(
            schema: Schema([PersistedPendingAnchor.self]),
            url: url
        )
        self.container = container
        self.context = ModelContext(container)
    }

    /// In-memory factory for tests.
    public static func inMemory() -> SwiftDataPendingAnchorStore {
        let schema = Schema([PersistedPendingAnchor.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return SwiftDataPendingAnchorStore(container: container)
    }

    private init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - PendingAnchorStore

    public func record(_ anchor: PendingAnchor) async throws {
        // Adds only — see the protocol. The epoch an attempt proves
        // from is not always one this device has persisted, so a sweep
        // here can delete the record for a landed transaction while the
        // group on disk still names the epoch before it.
        let row: PersistedPendingAnchor
        do {
            row = PersistedPendingAnchor(
                groupIDHex: anchor.groupID.hexString,
                ownerIdentityIDString: anchor.ownerIdentityID.rawValue.uuidString,
                epochOldBits: Int64(bitPattern: anchor.epochOld),
                createdAt: anchor.createdAt,
                encryptedJoinerPublicKey: try StorageEncryption.encrypt(anchor.joinerPublicKey),
                encryptedJoinerLeafHash: try StorageEncryption.encrypt(anchor.joinerLeafHash),
                encryptedSaltNew: try StorageEncryption.encrypt(anchor.saltNew)
            )
        } catch {
            throw StoreError.couldNotRecord("encrypt: \(error)")
        }

        context.insert(row)
        do {
            try context.save()
        } catch {
            // Roll the orphaned in-memory insert back out, as the other
            // stores do — a half-inserted object survives in the context
            // and a later save would commit it.
            context.delete(row)
            throw StoreError.couldNotRecord(String(describing: error))
        }
    }

    public func pending(groupID: Data, ownerIdentityID: IdentityID) async -> [PendingAnchor] {
        rows(groupIDHex: groupID.hexString, ownerIdentityID: ownerIdentityID)
            .sorted { $0.createdAt > $1.createdAt }
            // A row that won't decrypt is a row that can't identify a
            // landed transaction, so it is skipped rather than allowed
            // to fail the whole reconcile — the remaining candidates are
            // still worth checking.
            .compactMap { row in
                guard
                    let joinerPublicKey = try? StorageEncryption.decrypt(row.encryptedJoinerPublicKey),
                    let joinerLeafHash = try? StorageEncryption.decrypt(row.encryptedJoinerLeafHash),
                    let saltNew = try? StorageEncryption.decrypt(row.encryptedSaltNew)
                else { return nil }
                return PendingAnchor(
                    groupID: groupID,
                    ownerIdentityID: ownerIdentityID,
                    epochOld: UInt64(bitPattern: row.epochOldBits),
                    joinerPublicKey: joinerPublicKey,
                    joinerLeafHash: joinerLeafHash,
                    saltNew: saltNew,
                    createdAt: row.createdAt
                )
            }
    }

    public func clear(groupID: Data, ownerIdentityID: IdentityID, throughEpoch: UInt64) async {
        deleteRows(
            groupIDHex: groupID.hexString,
            ownerIdentityID: ownerIdentityID,
            throughEpoch: throughEpoch
        )
    }

    // MARK: - Private

    private func rows(
        groupIDHex: String,
        ownerIdentityID: IdentityID
    ) -> [PersistedPendingAnchor] {
        let owner = ownerIdentityID.rawValue.uuidString
        let descriptor = FetchDescriptor<PersistedPendingAnchor>(
            predicate: #Predicate { row in
                row.groupIDHex == groupIDHex && row.ownerIdentityIDString == owner
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Sweep every attempt that proved from `throughEpoch` or earlier.
    ///
    /// Filtered in Swift rather than in the predicate: the stored column
    /// is a bit pattern, and an epoch comparison expressed over it in
    /// `#Predicate` would order wrongly the moment the sign bit came
    /// into play. The table holds a handful of rows for one group.
    private func deleteRows(
        groupIDHex: String,
        ownerIdentityID: IdentityID,
        throughEpoch: UInt64
    ) {
        let doomed = rows(groupIDHex: groupIDHex, ownerIdentityID: ownerIdentityID)
            .filter { UInt64(bitPattern: $0.epochOldBits) <= throughEpoch }
        guard !doomed.isEmpty else { return }
        for row in doomed { context.delete(row) }
        try? context.save()
    }
}
