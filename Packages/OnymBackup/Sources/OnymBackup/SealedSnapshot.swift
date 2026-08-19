import Foundation

/// One sealed archive, ready to hand to the adapter.
///
/// The bytes are referenced by URL rather than held in memory: a snapshot
/// is routinely hundreds of megabytes, and the payment-refusal loop keeps
/// the same file on disk across a purchase (`UI-Backup-Object-HTTP.md`
/// §10.2). Re-sealing to retry would mint a new snapshot salt and
/// therefore a new digest, defeating both the retry and `already_retained`.
public struct SealedSnapshot: Sendable, Equatable {
    public let snapshotVersion: Int
    /// Stable across every retry of this logical operation. The operator
    /// reconciles on it when a response is lost.
    public let operationId: String
    public let snapshotReference: SnapshotReference
    /// Location of the sealed bytes on this device, under file protection.
    public let sealedBytesURL: URL
    public let sealedAt: Date
    /// The terms digest in force when the person consented. Pinned into
    /// the snapshot and checked against the operator's answer.
    public let acceptedTermsId: String
    /// The previous snapshot this one replaces, if any. An ordering hint
    /// for the client's own chain — never an instruction to the operator,
    /// which must not drop anything on its own initiative.
    public let supersedes: SnapshotReference?

    public init(
        operationId: String,
        snapshotReference: SnapshotReference,
        sealedBytesURL: URL,
        sealedAt: Date,
        acceptedTermsId: String,
        supersedes: SnapshotReference? = nil
    ) {
        self.snapshotVersion = 1
        self.operationId = operationId
        self.snapshotReference = snapshotReference
        self.sealedBytesURL = sealedBytesURL
        self.sealedAt = sealedAt
        self.acceptedTermsId = acceptedTermsId
        self.supersedes = supersedes
    }
}

/// What an erasure covers.
public enum ErasureScope: Sendable, Equatable {
    case snapshot(SnapshotReference)
    /// Every snapshot under this holder's access key.
    case all

    public var wireValue: String {
        switch self {
        case .snapshot(let reference): reference.digest
        case .all: "all"
        }
    }
}
