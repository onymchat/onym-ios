import Foundation

/// The seven operations of `UI-Backup.md` §6, as this client needs them.
///
/// The port carries sealed bytes, references, pinned-terms digests, and
/// typed outcomes — and nothing else. No wire object, no locator format,
/// no HTTP status, no authorization header crosses it
/// (`UI-Backup.md` §8.1). An adapter for a different retention technology
/// implements this same protocol without any caller changing.
///
/// What it deliberately cannot do: compose a snapshot, seal or open one,
/// hold a key, decide what is eligible, or restore an identity.
public protocol BackupPort: Sendable {
    /// Verify the operator's manifest, profile, and terms, and report what
    /// we would be enrolling under. Purely local plus fetches — nothing is
    /// uploaded, and no consent is implied.
    func connect() async throws -> BackupConnection

    /// The cheap refusal point. Called before a large upload so a
    /// `paymentRequired` costs one small request rather than the whole
    /// snapshot (`UI-Backup-Object-HTTP.md` §9.2).
    func preflight(_ snapshot: SealedSnapshot) async throws -> BackupPreflight

    /// Upload the sealed bytes and commit them. Idempotent by
    /// `operationId` and reference: a retry re-sends the same bytes and
    /// never re-seals.
    func uploadSnapshot(_ snapshot: SealedSnapshot, grant: BackupUploadGrant) async throws -> BackupOutcome

    /// Everything this holder's access key can enumerate at this operator.
    func listSnapshots() async throws -> [RetainedSnapshot]

    /// Fetch sealed bytes to `destination`. The caller verifies the full
    /// reference before treating any byte as restorable; a short or
    /// mismatching download is `incompleteSnapshot`, never a partial
    /// restore.
    func downloadSnapshot(_ reference: SnapshotReference, to destination: URL) async throws

    /// Request erasure and return the operator's signed receipt.
    /// An acknowledged-but-incomplete erasure is `erasureUnconfirmed`,
    /// carrying the receipt — it is not success.
    func eraseSnapshot(scope: ErasureScope) async throws -> ErasureReceipt

    /// The portable container for migration to another operator or to the
    /// person's own storage. Never gated on payment
    /// (`UI-Backup.md` §14.15).
    func exportSnapshots(to directory: URL) async throws -> BackupExport

    /// Reconcile an operation whose response was lost. Returns `nil` when
    /// the operator has no record, which stays `unknown` — it is never
    /// promoted to `retained` or `erased` (`UI-Backup.md` §7.13).
    func queryOutcome(operationId: String) async throws -> BackupOutcome?
}

/// What `connect` established, before anything was uploaded.
public struct BackupConnection: Sendable, Equatable {
    public let manifest: BackupOperatorManifest
    public let profile: BackupImplementationProfile
    public let terms: BackupTerms
    /// The digest the caller must pin into every snapshot it uploads under
    /// this connection.
    public var acceptedTermsId: String { terms.termsId }

    public init(
        manifest: BackupOperatorManifest,
        profile: BackupImplementationProfile,
        terms: BackupTerms
    ) {
        self.manifest = manifest
        self.profile = profile
        self.terms = terms
    }
}

/// The operator's answer to a preflight.
public enum BackupPreflight: Sendable, Equatable {
    /// Proceed; the grant describes how to send the bytes.
    case granted(BackupUploadGrant)
    /// This exact reference is already held for this holder. Nothing to do.
    case alreadyRetained(BackupOutcome)
}

/// Permission to upload one snapshot, in transfer chunks.
///
/// `chunkBytes` is transfer framing only. It has nothing to do with the
/// sealing chunk size, which is a property of the sealed container and is
/// invisible to the operator.
public struct BackupUploadGrant: Sendable, Equatable {
    public let uploadId: String
    public let chunkBytes: Int
    public let chunkCount: Int
    public let expiresAt: Date

    public init(uploadId: String, chunkBytes: Int, chunkCount: Int, expiresAt: Date) {
        self.uploadId = uploadId
        self.chunkBytes = chunkBytes
        self.chunkCount = chunkCount
        self.expiresAt = expiresAt
    }
}

/// The result of an export: sealed bytes verbatim, plus the evidence that
/// makes them meaningful somewhere else.
public struct BackupExport: Sendable, Equatable {
    public let directory: URL
    public let snapshots: [ExportedSnapshot]
    public let receipts: [ErasureReceipt]

    public init(directory: URL, snapshots: [ExportedSnapshot], receipts: [ErasureReceipt]) {
        self.directory = directory
        self.snapshots = snapshots
        self.receipts = receipts
    }

    public struct ExportedSnapshot: Sendable, Equatable {
        public let snapshotReference: SnapshotReference
        public let acceptedTermsId: String
        public let retainedAt: Date
        /// The sealed bytes, byte-identical to what was uploaded — so
        /// migration is an upload of the same bytes under the same
        /// reference, with no re-sealing.
        public let sealedBytesURL: URL

        public init(
            snapshotReference: SnapshotReference,
            acceptedTermsId: String,
            retainedAt: Date,
            sealedBytesURL: URL
        ) {
            self.snapshotReference = snapshotReference
            self.acceptedTermsId = acceptedTermsId
            self.retainedAt = retainedAt
            self.sealedBytesURL = sealedBytesURL
        }
    }
}
