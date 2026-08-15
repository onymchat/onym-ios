import Foundation

/// Provenance record for one seat selection made through discovery:
/// which component the user picked, which provider listed it, and the
/// exact manifest hash the pick was bound to.
///
/// **Provenance only** — the legacy per-seat configurations
/// (`RelayerConfiguration`, the Nostr fanout list, the Blossom server
/// list, the moderation mandate) remain the operational source of
/// truth. A discovery-driven pick writes BOTH this record and the
/// derived endpoint into the legacy configuration (the dual-write
/// lands with the consent UI); endpoints present in a legacy
/// configuration with no matching `ModuleSelection` are "Manual /
/// legacy" entries.
public struct ModuleSelection: Codable, Equatable, Hashable, Sendable {
    /// The seat this selection fills (e.g. "notary",
    /// "transport.message", "blob.storage", "moderation").
    public let seatType: String
    /// `onym:component:<id>` of the selected component.
    public let componentId: String
    /// `onym:component:<id>` of the discovery provider whose catalog
    /// the entry came from (the selection's source).
    public let providerId: String
    /// `sha256:<hex>` of the exact manifest bytes the user consented
    /// to — ties the selection to `PinnedConsentRecord` /
    /// `CatalogEntry.manifest.digest`.
    public let manifestHash: String
    /// The offer accepted at selection time, when the manifest carried
    /// offers.
    public let offerId: String?
    public let selectedAt: Date

    public init(
        seatType: String,
        componentId: String,
        providerId: String,
        manifestHash: String,
        offerId: String? = nil,
        selectedAt: Date
    ) {
        self.seatType = seatType
        self.componentId = componentId
        self.providerId = providerId
        self.manifestHash = manifestHash
        self.offerId = offerId
        self.selectedAt = selectedAt
    }
}

/// Persistence seam for selection provenance. One **active** selection
/// per seat type (the most recently recorded); prior records for that
/// seat are kept as bounded history so "what did I run in March, via
/// which provider?" stays answerable without growing without limit.
public protocol SeatSelectionStore: Sendable {
    /// The most recently recorded selection for `seatType`, or nil if
    /// no discovery-driven selection was ever made for that seat.
    func activeSelection(seatType: String) -> ModuleSelection?
    /// The retained selections for `seatType`, oldest first (the last
    /// element is the active selection).
    func history(seatType: String) -> [ModuleSelection]
    /// Record a selection. It becomes the active selection for its
    /// `seatType`; previously recorded selections stay in (bounded)
    /// history.
    func record(_ selection: ModuleSelection)
}

/// Serializes every `record` in the process — `record` is a
/// load-modify-save, and without mutual exclusion two concurrent
/// records read the same array and one selection is silently dropped.
/// A process-wide lock rather than an actor for the same reason as
/// `PinnedConsentStore`'s serialization: the flows that record a
/// selection are synchronous, and an actor hop would force that whole
/// path async for the same guarantee.
private enum SeatSelectionStoreSerialization {
    static let lock = NSLock()
}

/// Production `SeatSelectionStore`. Single UserDefaults blob under
/// `app.onym.ios.discovery.selections` — an append-only-shaped array
/// of records; "active" is a projection (last record per seat), not
/// separate state that could drift from the history.
///
/// Retention mirrors `PinnedConsentStore`'s treatment: per seat type,
/// the active selection plus the last `maxHistoryRecordsPerSeat`
/// prior records; the oldest beyond that are evicted on `record`.
///
/// `@unchecked Sendable` for the same reason as the sibling stores:
/// `UserDefaults` is documented thread-safe but not formally `Sendable`.
public struct UserDefaultsSeatSelectionStore: SeatSelectionStore, @unchecked Sendable {
    private static let key = "app.onym.ios.discovery.selections"

    /// Prior (non-active) records kept per seat type. Same cap as the
    /// consent store's per-component history — these records are tiny
    /// (no manifest bytes), but unbounded re-selection history in a
    /// UserDefaults blob is the same failure mode.
    static let maxHistoryRecordsPerSeat = 8

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func activeSelection(seatType: String) -> ModuleSelection? {
        history(seatType: seatType).last
    }

    public func history(seatType: String) -> [ModuleSelection] {
        loadAll().filter { $0.seatType == seatType }
    }

    public func record(_ selection: ModuleSelection) {
        SeatSelectionStoreSerialization.lock.lock()
        defer { SeatSelectionStoreSerialization.lock.unlock() }

        var all = loadAll()
        all.append(selection)
        // Retention: evict the oldest records of this seat type beyond
        // active + cap. Records of other seats are untouched.
        let seatIndices = all.indices.filter { all[$0].seatType == selection.seatType }
        let excess = seatIndices.count - (Self.maxHistoryRecordsPerSeat + 1)
        if excess > 0 {
            for index in seatIndices.prefix(excess).reversed() {
                all.remove(at: index)
            }
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func loadAll() -> [ModuleSelection] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([ModuleSelection].self, from: data)
        else { return [] }
        return all
    }
}
