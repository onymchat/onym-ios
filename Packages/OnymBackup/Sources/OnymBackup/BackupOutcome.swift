import Foundation

/// What an operator did, as far as we can honestly tell.
///
/// The distinctions here are the point of the type. `retained` is not a
/// restorability proof, a durability guarantee, or a statement about any
/// copy the operator does not control; `erased` is bounded by the receipt's
/// declared scope; and `unknown` is a real, terminal state that must never
/// be rendered as success (`UI-Backup.md` §5.7, §14.9).
public enum BackupOutcomeStatus: String, Sendable, Equatable, Codable, CaseIterable {
    /// Accepted into the local upload queue. Nothing has left the device.
    case queuedLocally = "queued_locally"
    /// The request body was handed to the network. Says nothing about receipt.
    case submitted
    /// The operator explicitly accepted the operation.
    case accepted
    /// The operator confirmed a matching stored snapshot under pinned terms.
    case retained
    /// The same reference was already held for this holder.
    case alreadyRetained = "already_retained"
    /// The operator explicitly refused, with a reason.
    case rejected
    /// The operator confirmed erasure within its declared scope.
    case erased
    /// No meaningful operator response was obtained.
    case unreachable
    /// The request may have succeeded; the result is inconclusive.
    /// Reconciled by reference through `queryOutcome`, never relabelled.
    case unknown

    /// True only for the states a person may honestly be shown as "your
    /// backup is on the operator". Deliberately excludes `submitted` and
    /// `accepted`: neither means the bytes are held.
    public var isRetention: Bool {
        self == .retained || self == .alreadyRetained
    }
}

/// One operator's answer to one operation.
///
/// Every field except `status` is an *observation* — the operator's own
/// claim, not a verified fact. `retainedUntil` in particular is a
/// statement, not a promise (`UI-Backup.md` §10.1).
public struct BackupOutcome: Sendable, Equatable {
    public let operationId: String
    public let componentId: String
    public let status: BackupOutcomeStatus
    public let snapshotReference: SnapshotReference?
    /// Profile-specific location hint. Untrusted: never used to drive
    /// navigation, execution, or a follow-up request to a new origin.
    public let locator: String?
    public let retainedUntil: Date?
    /// The terms digest the operator says it accepted this under. A
    /// mismatch against what we pinned is `termsChanged`, not a detail.
    public let termsId: String?
    public let evidence: Data?

    public init(
        operationId: String,
        componentId: String,
        status: BackupOutcomeStatus,
        snapshotReference: SnapshotReference? = nil,
        locator: String? = nil,
        retainedUntil: Date? = nil,
        termsId: String? = nil,
        evidence: Data? = nil
    ) {
        self.operationId = operationId
        self.componentId = componentId
        self.status = status
        self.snapshotReference = snapshotReference
        self.locator = locator
        self.retainedUntil = retainedUntil
        self.termsId = termsId
        self.evidence = evidence
    }
}

/// One row of `listSnapshots`.
public struct RetainedSnapshot: Sendable, Equatable {
    public let snapshotReference: SnapshotReference
    public let acceptedTermsId: String
    public let retainedAt: Date
    public let retainedUntil: Date?
    public let supersedes: String?
    public let status: BackupOutcomeStatus

    public init(
        snapshotReference: SnapshotReference,
        acceptedTermsId: String,
        retainedAt: Date,
        retainedUntil: Date? = nil,
        supersedes: String? = nil,
        status: BackupOutcomeStatus = .retained
    ) {
        self.snapshotReference = snapshotReference
        self.acceptedTermsId = acceptedTermsId
        self.retainedAt = retainedAt
        self.retainedUntil = retainedUntil
        self.supersedes = supersedes
        self.status = status
    }
}
