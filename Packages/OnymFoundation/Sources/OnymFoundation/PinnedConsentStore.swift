import Foundation

/// Persistence seam for pinned consent records. UserDefaults-backed —
/// a consent record is a local pin of public manifest bytes, not a
/// secret. Same load/save shape as `MandateStore` in OnymModeration.
public protocol PinnedConsentStore: Sendable {
    func load() -> [PinnedConsentRecord]
    func save(_ records: [PinnedConsentRecord])
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
    /// Atomic: the load-modify-save is serialized process-wide, so
    /// concurrent accepts (even through different store instances over
    /// the same defaults) cannot drop each other's records or leave
    /// two records active for one componentId.
    @discardableResult
    func accept(
        _ reviewed: ReviewedServiceManifest,
        sourceLabel: String? = nil,
        offerId: String? = nil,
        acceptedAt: Date = Date()
    ) -> PinnedConsentRecord {
        PinnedConsentStoreSerialization.lock.lock()
        defer { PinnedConsentStoreSerialization.lock.unlock() }

        var records = load()
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

        save(records)
        return record
    }

    /// The active consent for a component, if any.
    func activeRecord(componentId: String) -> PinnedConsentRecord? {
        load().last { $0.componentId == componentId && $0.isActive }
    }
}

/// Production `PinnedConsentStore`. Key scoped under
/// `app.onym.ios.consent.*`; suite injectable for test isolation.
///
/// `@unchecked Sendable` because `UserDefaults` is documented as
/// thread-safe but isn't formally `Sendable`.
public struct UserDefaultsPinnedConsentStore: PinnedConsentStore, @unchecked Sendable {
    private static let recordsKey = "app.onym.ios.consent.records"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [PinnedConsentRecord] {
        guard let data = defaults.data(forKey: Self.recordsKey),
              let records = try? Self.decoder().decode([PinnedConsentRecord].self, from: data)
        else { return [] }
        return records
    }

    public func save(_ records: [PinnedConsentRecord]) {
        guard let data = try? Self.encoder().encode(records) else { return }
        defaults.set(data, forKey: Self.recordsKey)
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
