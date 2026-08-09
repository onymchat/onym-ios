import Foundation
import OnymFoundation

/// Exact signed report retained across ambiguous delivery outcomes.
/// Successful records remain as a local idempotency ledger so tapping
/// Report twice cannot mint a second allegation for the same evidence.
public struct ReportFilingRecord: Codable, Sendable, Equatable {
    public let sourceMessageId: String
    public let report: Report
    public let authorityName: String
    public var receipt: ReportReceipt?
    /// The Authority answered 409 for these exact bytes: the report is
    /// on file but the original receipt is unrecoverable. Terminal like
    /// `receipt` — the row prunes under the resolved bound and a later
    /// Submit short-circuits instead of re-delivering. Optional so
    /// records persisted before this field decode as nil.
    public var resolvedWithoutReceipt: Bool?

    public init(
        sourceMessageId: String,
        report: Report,
        authorityName: String,
        receipt: ReportReceipt? = nil,
        resolvedWithoutReceipt: Bool? = nil
    ) {
        self.sourceMessageId = sourceMessageId
        self.report = report
        self.authorityName = authorityName
        self.receipt = receipt
        self.resolvedWithoutReceipt = resolvedWithoutReceipt
    }

    /// A row that reached a terminal outcome (accepted with a receipt,
    /// or confirmed already-on-file) — retained only as history, so it
    /// is eligible for retention pruning.
    public var isResolved: Bool {
        receipt != nil || resolvedWithoutReceipt == true
    }
}

public protocol ReportFilingStore: Sendable {
    func load() -> [ReportFilingRecord]
    func save(_ records: [ReportFilingRecord]) throws
}

public struct UserDefaultsReportFilingStore: ReportFilingStore, @unchecked Sendable {
    private static let recordsKey = "app.onym.ios.moderation.reports"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [ReportFilingRecord] {
        guard let encrypted = defaults.data(forKey: Self.recordsKey),
              let data = try? StorageEncryption.decrypt(encrypted),
              let records = try? Self.decoder().decode([ReportFilingRecord].self, from: data)
        else { return [] }
        return records
    }

    public func save(_ records: [ReportFilingRecord]) throws {
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

public final class InMemoryReportFilingStore: ReportFilingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ReportFilingRecord]

    public init(records: [ReportFilingRecord] = []) {
        self.records = records
    }

    public func load() -> [ReportFilingRecord] {
        lock.withLock { records }
    }

    public func save(_ records: [ReportFilingRecord]) {
        lock.withLock { self.records = records }
    }
}
