import Foundation

/// Notice of an opened case, served to the accused through the
/// interface (Moderation.md §5.5). The interface must present it with
/// the evidence, the consented class definition, and the response
/// path; the case-open mark is procedural state and must not degrade
/// service.
public struct CaseNotice: Codable, Sendable, Equatable {
    public let noticeVersion: Int
    public let caseId: String
    public let authority: String
    public let accused: String
    /// Hash of the accused's mandate.
    public let mandateRef: String
    public let classId: String
    /// Hash of the disclosed items the case rests on.
    public let evidenceSummary: String
    public let responseDeadline: Date
    public let decisionDeadline: Date
    public let signature: String

    public init(
        noticeVersion: Int = 1,
        caseId: String,
        authority: String,
        accused: String,
        mandateRef: String,
        classId: String,
        evidenceSummary: String,
        responseDeadline: Date,
        decisionDeadline: Date,
        signature: String
    ) {
        self.noticeVersion = noticeVersion
        self.caseId = caseId
        self.authority = authority
        self.accused = accused
        self.mandateRef = mandateRef
        self.classId = classId
        self.evidenceSummary = evidenceSummary
        self.responseDeadline = responseDeadline
        self.decisionDeadline = decisionDeadline
        self.signature = signature
    }
}
