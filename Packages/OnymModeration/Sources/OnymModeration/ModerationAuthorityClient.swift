import Foundation

/// Receipt for a filed report. Intake weighting (reporter track
/// record) is the authority's business; the client only learns the
/// report was received.
public struct ReportReceipt: Codable, Sendable, Equatable {
    public let reportId: String
    public let receivedAt: Date

    public init(reportId: String, receivedAt: Date) {
        self.reportId = reportId
        self.receivedAt = receivedAt
    }
}

/// The accused's signed response to a case notice: statements and
/// counter-evidence (Moderation.md §5.5 — "the response mirrors the
/// report's shape"). Additional evidence within the window travels
/// through the same object, so `submit-evidence` needs no separate
/// operation client-side.
public struct CaseResponse: Codable, Sendable, Equatable {
    public let statement: String
    public let evidence: [EvidenceItem]
    public var signature: String

    public init(statement: String, evidence: [EvidenceItem] = [], signature: String = "") {
        self.statement = statement
        self.evidence = evidence
        self.signature = signature
    }

    /// The bytes the accused signs: every field except `signature`.
    /// See `ModerationCanonicalEncoder` for why the ordering matters.
    public func signingBytes() throws -> Data {
        struct Unsigned: Encodable {
            let statement: String
            let evidence: [EvidenceItem]
        }
        return try ModerationCanonicalEncoder.encode(
            Unsigned(statement: statement, evidence: evidence)
        )
    }
}

/// An appeal filed within the declared window — or a new-holder claim,
/// which the spec treats as a mandatory appeal class with expedited
/// review (§5.7, error `new_holder_claim`).
public struct AppealSubmission: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case appeal
        case newHolderClaim = "new-holder-claim"
    }

    public let kind: Kind
    public let statement: String
    public var signature: String

    public init(kind: Kind, statement: String, signature: String = "") {
        self.kind = kind
        self.statement = statement
        self.signature = signature
    }

    /// The bytes the accused signs: every field except `signature`.
    ///
    /// A `newHolderClaim` is signed too where the holder still has the
    /// mandated identity, but an authority cannot require it — the
    /// whole premise of that path is a device whose new owner is *not*
    /// the mandated user (§5.7).
    public func signingBytes() throws -> Data {
        struct Unsigned: Encodable {
            let kind: Kind
            let statement: String
        }
        return try ModerationCanonicalEncoder.encode(
            Unsigned(kind: kind, statement: statement)
        )
    }
}

/// Stage-and-deadlines answer to a status query, per the authority's
/// confidentiality rules.
public struct CaseStatus: Codable, Sendable, Equatable {
    public let caseId: String
    public let stage: String
    public let responseDeadline: Date?
    public let decisionDeadline: Date?

    public init(caseId: String, stage: String, responseDeadline: Date? = nil, decisionDeadline: Date? = nil) {
        self.caseId = caseId
        self.stage = stage
        self.responseDeadline = responseDeadline
        self.decisionDeadline = decisionDeadline
    }
}

/// The client-visible operations of a moderation authority
/// (Moderation.md §6). Notices and verdicts travel the other way —
/// they arrive via the enforcement backend's gate check — so this
/// surface is only what a user initiates.
///
/// Deliberately smaller than the spec's operation table:
/// `submit-evidence` is folded into `respond` (same signed shape, same
/// window), and `accept-mandate` is authority-side. One implementation
/// per authority; the repository picks the client for the mandated
/// authority, which is what makes authorities swappable.
public protocol ModerationAuthorityClient: Sendable {
    func fileReport(_ report: Report) async throws -> ReportReceipt
    func respond(caseId: String, _ response: CaseResponse) async throws
    func appeal(caseId: String, _ submission: AppealSubmission) async throws
    func queryStatus(caseId: String) async throws -> CaseStatus
}

/// Stub client — no authority service is deployed yet. Every
/// operation throws `.notImplemented` so UI entry points exist and
/// fail honestly rather than pretending a case moved.
public struct StubModerationAuthorityClient: ModerationAuthorityClient {
    public init() {}

    public func fileReport(_ report: Report) async throws -> ReportReceipt {
        throw ModerationError.notImplemented("file-report")
    }

    public func respond(caseId: String, _ response: CaseResponse) async throws {
        throw ModerationError.notImplemented("respond")
    }

    public func appeal(caseId: String, _ submission: AppealSubmission) async throws {
        throw ModerationError.notImplemented("appeal")
    }

    public func queryStatus(caseId: String) async throws -> CaseStatus {
        throw ModerationError.notImplemented("query-status")
    }
}
