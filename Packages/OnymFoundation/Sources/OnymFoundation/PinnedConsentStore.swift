import Foundation

/// Why the consent store refused to load or persist.
public enum PinnedConsentStoreError: Error, Equatable, Sendable {
    /// Bytes exist under the records key but no longer decode. The
    /// store must **never** treat this as "no records": the next
    /// `accept` would save a fresh array over the key and silently
    /// destroy every prior consent record — exactly what the
    /// immutable-artifact design exists to prevent. The corrupt blob
    /// is parked under a `.corrupt` sibling key for forensics; accepts
    /// are refused until the corruption is explicitly cleared
    /// (`clearCorruptRecords()` on the UserDefaults store).
    case corruptStore(reason: String)
    /// The records could not be encoded or written. `accept` throws
    /// this rather than returning a record that was never persisted.
    case persistenceFailed(reason: String)
}

/// Persistence seam for pinned consent records. UserDefaults-backed —
/// a consent record is a local pin of public manifest bytes, not a
/// secret. Same load/save shape as `MandateStore` in OnymModeration,
/// plus throwing: `load` must distinguish "no records yet" (empty
/// array) from "records exist but are corrupt" (`corruptStore`), and
/// `save` must surface a failed write (`persistenceFailed`) so
/// `accept` can never report consent it did not persist.
public protocol PinnedConsentStore: Sendable {
    func load() throws -> [PinnedConsentRecord]
    func save(_ records: [PinnedConsentRecord]) throws
}

/// Serializes every `accept` in the process. `accept` is a
/// load-modify-save; without mutual exclusion two concurrent accepts
/// read the same array and one record is silently dropped — or two
/// records end up active for one componentId. A process-wide lock
/// rather than an actor because the consent flows that call `accept`
/// are synchronous (SwiftUI actions, `ModuleConsentAcceptance`), and
/// an actor hop would force that whole path async for the same
/// mutual exclusion. Moderation solves the same problem by keeping
/// its flow inside `ModerationRepository`'s actor; this is the
/// equivalent guarantee for the generic primitive.
private enum PinnedConsentStoreSerialization {
    static let lock = NSLock()
}

public extension PinnedConsentStore {
    /// Inactive records kept per componentId, newest first — the
    /// active pin plus this much history. Manifests are full snapshots
    /// in UserDefaults, so unbounded re-consent history would grow
    /// without limit; moderation caps its analogous ledger the same
    /// way (`maxResolvedReportRecords = 128`, scaled down here because
    /// each record carries whole manifest bytes).
    internal static var maxInactiveRecordsPerComponent: Int { 8 }

    /// Mint and persist consent to a reviewed manifest.
    ///
    /// Takes a `ReviewedServiceManifest` — not raw bytes — so only
    /// reviewer-verified bytes can be pinned. Accepting a record for a
    /// componentId that already has one deactivates the previous
    /// record and keeps it as history (`MandateRecord` style: consent
    /// artifacts are immutable, switching is a fresh record). History
    /// is capped at `maxInactiveRecordsPerComponent`, oldest evicted.
    ///
    /// The load-modify-save is serialized **in-process** (one lock
    /// shared by every store instance in this process), so concurrent
    /// accepts on any queues of this process cannot drop each other's
    /// records or leave two records active for one componentId. The
    /// lock does not reach across processes: an app and its extensions
    /// writing the same defaults suite are not mutually excluded here.
    ///
    /// Throws `PinnedConsentStoreError.corruptStore` without writing
    /// anything when the existing records fail to load — a corrupt
    /// store is never overwritten — and
    /// `PinnedConsentStoreError.persistenceFailed` when the save
    /// fails, so a returned record always means persisted consent.
    @discardableResult
    func accept(
        _ reviewed: ReviewedServiceManifest,
        sourceLabel: String? = nil,
        offerId: String? = nil,
        acceptedAt: Date = Date()
    ) throws -> PinnedConsentRecord {
        PinnedConsentStoreSerialization.lock.lock()
        defer { PinnedConsentStoreSerialization.lock.unlock() }

        var records = try load()
        let componentId = reviewed.signedManifest.componentId
        for index in records.indices where records[index].componentId == componentId {
            records[index].isActive = false
        }
        let record = PinnedConsentRecord(
            reviewed: reviewed,
            sourceLabel: sourceLabel,
            offerId: offerId,
            acceptedAt: acceptedAt,
            isActive: true
        )
        records.append(record)

        // Retention: evict the oldest inactive records of this
        // componentId beyond the cap. Records of other components and
        // the just-appended active record are untouched.
        let inactiveIndices = records.indices.filter {
            records[$0].componentId == componentId && !records[$0].isActive
        }
        let excess = inactiveIndices.count - Self.maxInactiveRecordsPerComponent
        if excess > 0 {
            for index in inactiveIndices.prefix(excess).reversed() {
                records.remove(at: index)
            }
        }

        try save(records)
        return record
    }

    /// Withdraw consent for a component: every record for it becomes
    /// history, and none is active.
    ///
    /// There was no way to do this, and for a single-seat consent it did
    /// not show: consenting to a replacement deactivated the previous
    /// record for the *same* componentId, so switching worked and
    /// leaving was never asked for. A seat a person can hold with
    /// several operators at once makes the gap expensive — every
    /// operator ever consented to stays active, keeps receiving a copy
    /// of the history, and keeps charging for it, with no route out.
    ///
    /// The records are kept, deactivated, exactly as a switch keeps
    /// them. A consent artifact is evidence that something was agreed;
    /// leaving is a new fact about it, not a reason to erase it.
    ///
    /// Returns whether anything changed, so a caller can tell a
    /// withdrawal from a no-op.
    @discardableResult
    func withdraw(componentId: String) throws -> Bool {
        PinnedConsentStoreSerialization.lock.lock()
        defer { PinnedConsentStoreSerialization.lock.unlock() }

        var records = try load()
        var changed = false
        for index in records.indices
        where records[index].componentId == componentId && records[index].isActive {
            records[index].isActive = false
            changed = true
        }
        guard changed else { return false }
        try save(records)
        return true
    }

    /// The active consent for a component, if any. Throws
    /// `corruptStore` rather than pretending no consent exists.
    func activeRecord(componentId: String) throws -> PinnedConsentRecord? {
        try load().last { $0.componentId == componentId && $0.isActive }
    }
}

/// Production `PinnedConsentStore`. Key scoped under
/// `app.onym.ios.consent.*`; suite injectable for test isolation.
///
/// Corruption handling: if the stored blob stops decoding, `load`
/// copies it under `app.onym.ios.consent.records.corrupt` (forensics —
/// the bytes are preserved even if something later replaces the live
/// key) and throws `corruptStore`. Because `accept` propagates that
/// throw before writing, a corrupt store is never overwritten by a new
/// consent; recovery is an explicit `clearCorruptRecords()` call by
/// whatever surface decides the history is unrecoverable.
///
/// `@unchecked Sendable` because `UserDefaults` is documented as
/// thread-safe but isn't formally `Sendable`.
public struct UserDefaultsPinnedConsentStore: PinnedConsentStore, @unchecked Sendable {
    private static let recordsKey = "app.onym.ios.consent.records"
    private static let corruptRecordsKey = "app.onym.ios.consent.records.corrupt"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> [PinnedConsentRecord] {
        guard let data = defaults.data(forKey: Self.recordsKey) else { return [] }
        do {
            return try Self.decoder().decode([PinnedConsentRecord].self, from: data)
        } catch {
            // Park the undecodable blob for forensics, keep the live
            // key as-is, and refuse: absent and corrupt must never
            // look the same, or the next accept destroys all history.
            defaults.set(data, forKey: Self.corruptRecordsKey)
            throw PinnedConsentStoreError.corruptStore(reason: String(describing: error))
        }
    }

    public func save(_ records: [PinnedConsentRecord]) throws {
        let data: Data
        do {
            data = try Self.encoder().encode(records)
        } catch {
            throw PinnedConsentStoreError.persistenceFailed(reason: String(describing: error))
        }
        defaults.set(data, forKey: Self.recordsKey)
    }

    /// Whether a corrupt blob has been parked. Surfaces the error
    /// state without another failing `load`.
    public var hasCorruptRecords: Bool {
        defaults.data(forKey: Self.corruptRecordsKey) != nil
    }

    /// Give up on a corrupt store: remove the live records key (so
    /// `load` returns `[]` and accepts work again) and the parked
    /// blob. Destructive and deliberate — nothing calls this
    /// automatically.
    public func clearCorruptRecords() {
        defaults.removeObject(forKey: Self.recordsKey)
        defaults.removeObject(forKey: Self.corruptRecordsKey)
    }

    /// ISO 8601 dates, matching every other persisted consent object.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
