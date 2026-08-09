import Foundation

/// One disclosed item of evidence (Moderation.md §5.4): a message or
/// media the reporter legitimately received, with proof the accused
/// authored it. Content without an authenticity proof is a complaint,
/// not evidence.
public struct EvidenceItem: Codable, Sendable, Equatable {
    /// The specific message or media, from the reporter's own device.
    public let disclosedContent: String
    /// Sender signature or envelope commitment binding the content to
    /// the accused's key.
    public let authenticityProof: String
    /// Optional conversation context the reporter chooses to add.
    public let context: String?

    public init(disclosedContent: String, authenticityProof: String, context: String? = nil) {
        self.disclosedContent = disclosedContent
        self.authenticityProof = authenticityProof
        self.context = context
    }
}

/// A signed report of prohibited content (Moderation.md §5.4), filed
/// voluntarily by a recipient of the content.
public struct Report: Codable, Sendable, Equatable {
    public let reportVersion: Int
    public let reportId: String
    public let reporter: String
    /// Hash of the reporter's own mandate — standing follows the
    /// reporter's consent (spec §5.4 constraint 5).
    public let reporterMandate: String
    public let accused: String
    public let classId: String
    public let evidence: [EvidenceItem]
    public let filedAt: Date
    public var signature: String

    public init(
        reportVersion: Int = 1,
        reportId: String,
        reporter: String,
        reporterMandate: String,
        accused: String,
        classId: String,
        evidence: [EvidenceItem],
        filedAt: Date,
        signature: String = ""
    ) {
        self.reportVersion = reportVersion
        self.reportId = reportId
        self.reporter = reporter
        self.reporterMandate = reporterMandate
        self.accused = accused
        self.classId = classId
        self.evidence = evidence
        self.filedAt = filedAt
        self.signature = signature
    }

    /// The bytes the reporter signs: every field except `signature`.
    ///
    /// Keys sort by **UTF-8 byte order**, which is what
    /// `JSONEncoder.OutputFormatting.sortedKeys` does. That is not a
    /// free choice here: `Foundation` also offers
    /// `JSONSerialization`'s `.sortedKeys`, which sorts
    /// *case-insensitively*, and `Report` is the one moderation object
    /// whose keys actually disagree between the two —
    /// `reportId` and `reportVersion` precede `reporter` by byte order
    /// and follow it case-insensitively. An authority reconstructing
    /// these bytes with a byte-ordered JSON library (serde_json, Go's
    /// encoding/json, Python's `sort_keys`) would reject every
    /// signature produced the other way, so this must stay on
    /// `JSONEncoder`. `ModerationCanonicalOrderTests` pins exactly that.
    ///
    /// Same PROVISIONAL caveat as `ModerationMandate.signingBytes()`:
    /// the draft spec fixes no canonical JSON form, so this agreement
    /// holds by construction between implementations rather than by
    /// specification.
    public func signingBytes() throws -> Data {
        struct Unsigned: Encodable {
            let reportVersion: Int
            let reportId, reporter, reporterMandate, accused, classId: String
            let evidence: [EvidenceItem]
            let filedAt: Date
        }
        let unsigned = Unsigned(
            reportVersion: reportVersion,
            reportId: reportId,
            reporter: reporter,
            reporterMandate: reporterMandate,
            accused: accused,
            classId: classId,
            evidence: evidence,
            filedAt: filedAt
        )
        return try ModerationCanonicalEncoder.encode(unsigned)
    }
}
