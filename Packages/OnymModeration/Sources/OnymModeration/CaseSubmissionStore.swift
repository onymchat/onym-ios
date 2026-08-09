import Foundation
import OnymFoundation

/// Exact signed case submission (response or appeal), retained across
/// ambiguous delivery outcomes so a retry re-delivers byte-identical
/// content — never differently signed content. Records with a receipt
/// remain as a local idempotency ledger: the reference Authority does
/// NOT deduplicate responses (each delivery files a new row, bounded
/// at 32 per case), so client-side "same statement → same artifact →
/// return the stored receipt" is the only thing keeping a double-tap
/// or a re-entered identical statement from filing twice.
public struct CaseSubmissionRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case response
        case appeal
        case newHolderClaim
    }

    /// Stable row identity, so ledger mutations can never alias two
    /// rows that happen to share content and a (test-fixed) clock.
    public let id: UUID
    public let caseId: String
    public let mandateRef: String
    /// `onym:key:` reference of the LOCAL identity that filed this
    /// submission, for identity-removal purge (same contract as the
    /// other ledgers). For a response or ordinary appeal this equals
    /// the case mandate's user; for a new-holder claim it is the
    /// device's current identity — the mandated user is by premise not
    /// local, and keying the row to them would let the purge silently
    /// drop a pending claim's retry artifact.
    public let user: String
    public let authorityName: String
    public let kind: Kind
    /// Exactly one of these is set, matching `kind`. Stored whole —
    /// including the signature — so retry re-encodes the identical
    /// canonical bytes.
    public let response: CaseResponse?
    public let appeal: AppealSubmission?
    public var responseReceipt: CaseResponseReceipt?
    public var appealReceipt: AppealReceipt?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        caseId: String,
        mandateRef: String,
        user: String,
        authorityName: String,
        kind: Kind,
        response: CaseResponse? = nil,
        appeal: AppealSubmission? = nil,
        responseReceipt: CaseResponseReceipt? = nil,
        appealReceipt: AppealReceipt? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.caseId = caseId
        self.mandateRef = mandateRef
        self.user = user
        self.authorityName = authorityName
        self.kind = kind
        self.response = response
        self.appeal = appeal
        self.responseReceipt = responseReceipt
        self.appealReceipt = appealReceipt
        self.createdAt = createdAt
    }

    /// Delivery reached a terminal acknowledged outcome; the row is
    /// retained only as the idempotency ledger and prunes under the
    /// resolved retention bound.
    public var isResolved: Bool {
        responseReceipt != nil || appealReceipt != nil
    }
}

public protocol CaseSubmissionStore: Sendable {
    func load() -> [CaseSubmissionRecord]
    func save(_ records: [CaseSubmissionRecord]) throws
}

/// Encrypted-at-rest, same posture as the report ledger — a statement
/// is the user's own words about an accusation and never lands in
/// UserDefaults as plaintext.
public struct UserDefaultsCaseSubmissionStore: CaseSubmissionStore, @unchecked Sendable {
    private static let recordsKey = "app.onym.ios.moderation.caseSubmissions"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [CaseSubmissionRecord] {
        guard let encrypted = defaults.data(forKey: Self.recordsKey),
              let data = try? StorageEncryption.decrypt(encrypted),
              let records = try? Self.decoder().decode([CaseSubmissionRecord].self, from: data)
        else { return [] }
        return records
    }

    public func save(_ records: [CaseSubmissionRecord]) throws {
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

public final class InMemoryCaseSubmissionStore: CaseSubmissionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CaseSubmissionRecord]

    public init(records: [CaseSubmissionRecord] = []) {
        self.records = records
    }

    public func load() -> [CaseSubmissionRecord] {
        lock.withLock { records }
    }

    public func save(_ records: [CaseSubmissionRecord]) {
        lock.withLock { self.records = records }
    }
}
