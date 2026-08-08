import Foundation

/// The two device-mark states the abstract rail defines (Moderation.md
/// §5.7). Spec JSON keys are `"case-open"` / `"banned"`.
public struct Marks: Codable, Sendable, Equatable {
    public let caseOpen: Bool
    public let banned: Bool

    enum CodingKeys: String, CodingKey {
        case caseOpen = "case-open"
        case banned
    }

    public init(caseOpen: Bool, banned: Bool) {
        self.caseOpen = caseOpen
        self.banned = banned
    }
}

/// A signed verdict (Moderation.md §5.6) — the only object that moves
/// device marks. The client validates shape mechanically for display;
/// mark execution is the enforcement backend's job.
public struct Verdict: Codable, Sendable, Equatable {
    public enum Disposition: String, Codable, Sendable, Equatable {
        case openCase = "open-case"
        case dismiss
        case ban
    }

    public let verdictVersion: Int
    public let caseId: String
    public let authority: String
    /// Hash of the accused's mandate — must resolve to a mandate this
    /// user actually signed.
    public let mandateRef: String
    public let accusedKeys: [String]
    public let deviceBinding: String
    public let classId: String
    public let disposition: Disposition
    public let marks: Marks
    /// Required on bans unless the consented class term is `permanent`.
    public let banExpires: Date?
    /// When writing the banned mark becomes conforming: `decidedAt`
    /// for non-suspensive classes, `appealDeadline` for suspensive
    /// ones (§5.6 constraint 4). Required on every ban.
    public let executeAfter: Date?
    /// Content address of the findings. Mandatory — an unexplained
    /// sanction is nonconforming.
    public let reasoning: String
    public let appealDeadline: Date?
    public let decidedAt: Date
    public let signature: String
    /// False until the appeal deadline passes or the appeal concludes.
    public let isFinal: Bool

    enum CodingKeys: String, CodingKey {
        case verdictVersion, caseId, authority, mandateRef, accusedKeys
        case deviceBinding, classId, disposition, marks, banExpires
        case executeAfter, reasoning, appealDeadline, decidedAt, signature
        case isFinal = "final"
    }

    public init(
        verdictVersion: Int = 1,
        caseId: String,
        authority: String,
        mandateRef: String,
        accusedKeys: [String],
        deviceBinding: String,
        classId: String,
        disposition: Disposition,
        marks: Marks,
        banExpires: Date? = nil,
        executeAfter: Date? = nil,
        reasoning: String,
        appealDeadline: Date? = nil,
        decidedAt: Date,
        signature: String,
        isFinal: Bool
    ) {
        self.verdictVersion = verdictVersion
        self.caseId = caseId
        self.authority = authority
        self.mandateRef = mandateRef
        self.accusedKeys = accusedKeys
        self.deviceBinding = deviceBinding
        self.classId = classId
        self.disposition = disposition
        self.marks = marks
        self.banExpires = banExpires
        self.executeAfter = executeAfter
        self.reasoning = reasoning
        self.appealDeadline = appealDeadline
        self.decidedAt = decidedAt
        self.signature = signature
        self.isFinal = isFinal
    }

    /// The bytes the authority signs: every field except `signature`,
    /// JSON with sorted keys + ISO 8601 dates. Same PROVISIONAL caveat
    /// as `ModerationMandate.signingBytes()` — no canonical JSON exists
    /// in the draft spec yet.
    public func signingBytes() throws -> Data {
        struct Unsigned: Encodable {
            let verdictVersion: Int
            let caseId, authority, mandateRef: String
            let accusedKeys: [String]
            let deviceBinding, classId: String
            let disposition: Disposition
            let marks: Marks
            let banExpires, executeAfter: Date?
            let reasoning: String
            let appealDeadline: Date?
            let decidedAt: Date
            let `final`: Bool
        }
        let unsigned = Unsigned(
            verdictVersion: verdictVersion,
            caseId: caseId,
            authority: authority,
            mandateRef: mandateRef,
            accusedKeys: accusedKeys,
            deviceBinding: deviceBinding,
            classId: classId,
            disposition: disposition,
            marks: marks,
            banExpires: banExpires,
            executeAfter: executeAfter,
            reasoning: reasoning,
            appealDeadline: appealDeadline,
            decidedAt: decidedAt,
            final: isFinal
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(unsigned)
    }
}
