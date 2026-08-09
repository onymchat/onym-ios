import Foundation
import OnymFoundation

/// The last authenticated case-status document fetched for one case,
/// retained so the case surface can render offline and across
/// relaunches. A snapshot is a cache of the Authority's answer — the
/// Authority remains the source of truth, and a stale snapshot is
/// replaced wholesale by the next successful fetch.
public struct CaseStatusRecord: Codable, Sendable, Equatable {
    public let caseId: String
    /// Content reference of the mandate this case proceeds under.
    /// Standing follows this mandate — not the currently active one —
    /// so the record keeps the linkage the next fetch must re-resolve.
    public let mandateRef: String
    /// `onym:key:` reference of the mandated user, retained so
    /// identity removal can purge the snapshots that identity owned.
    public let user: String
    public var status: CaseStatus
    public var fetchedAt: Date

    public init(
        caseId: String,
        mandateRef: String,
        user: String,
        status: CaseStatus,
        fetchedAt: Date
    ) {
        self.caseId = caseId
        self.mandateRef = mandateRef
        self.user = user
        self.status = status
        self.fetchedAt = fetchedAt
    }
}

public protocol CaseStatusStore: Sendable {
    func load() -> [CaseStatusRecord]
    func save(_ records: [CaseStatusRecord]) throws
}

/// Encrypted-at-rest store, same posture as the report ledger: the
/// status document names the violation class and deadlines of an
/// accusation against this device's user, so it never lands in
/// UserDefaults as plaintext.
public struct UserDefaultsCaseStatusStore: CaseStatusStore, @unchecked Sendable {
    private static let recordsKey = "app.onym.ios.moderation.caseStatus"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [CaseStatusRecord] {
        guard let encrypted = defaults.data(forKey: Self.recordsKey),
              let data = try? StorageEncryption.decrypt(encrypted),
              let records = try? Self.decoder().decode([CaseStatusRecord].self, from: data)
        else { return [] }
        return records
    }

    public func save(_ records: [CaseStatusRecord]) throws {
        let data = try Self.encoder().encode(records)
        let encrypted = try StorageEncryption.encrypt(data)
        defaults.set(encrypted, forKey: Self.recordsKey)
    }

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

public final class InMemoryCaseStatusStore: CaseStatusStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CaseStatusRecord]

    public init(records: [CaseStatusRecord] = []) {
        self.records = records
    }

    public func load() -> [CaseStatusRecord] {
        lock.withLock { records }
    }

    public func save(_ records: [CaseStatusRecord]) {
        lock.withLock { self.records = records }
    }
}
