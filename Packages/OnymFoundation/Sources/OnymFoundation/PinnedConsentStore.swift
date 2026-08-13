import Foundation

/// Persistence seam for pinned consent records. UserDefaults-backed —
/// a consent record is a local pin of public manifest bytes, not a
/// secret. Same load/save shape as `MandateStore` in OnymModeration.
public protocol PinnedConsentStore: Sendable {
    func load() -> [PinnedConsentRecord]
    func save(_ records: [PinnedConsentRecord])
}

public extension PinnedConsentStore {
    /// Mint and persist consent to a reviewed manifest.
    ///
    /// Takes a `ReviewedServiceManifest` — not raw bytes — so only
    /// reviewer-verified bytes can be pinned. Accepting a record for a
    /// componentId that already has one deactivates the previous
    /// record and keeps it as history (`MandateRecord` style: consent
    /// artifacts are immutable, switching is a fresh record).
    @discardableResult
    func accept(
        _ reviewed: ReviewedServiceManifest,
        sourceLabel: String? = nil,
        offerId: String? = nil,
        acceptedAt: Date = Date()
    ) -> PinnedConsentRecord {
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
