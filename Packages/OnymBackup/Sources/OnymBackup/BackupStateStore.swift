import Foundation

/// What this device remembers about its own backups.
///
/// Small, local, and deliberately not authoritative about anything the
/// operator holds: the operator's `listSnapshots` is the truth about
/// what is retained, and this records what *we* did and what we were
/// promised when we did it.
public struct BackupState: Sendable, Equatable, Codable {
    public var componentId: String?
    /// The terms digest in force at the last consent. Every snapshot
    /// pins this; a change means uploads stop until the person has seen
    /// the new terms.
    public var acceptedTermsId: String?
    /// The exact terms bytes consented to, kept so a regression check
    /// has something to compare against after the operator has moved on.
    public var acceptedTermsRaw: Data?
    public var mediaPolicy: BackupMediaPolicy = .descriptorsOnly
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    /// The snapshot chain this device believes it uploaded, newest last.
    public var snapshots: [RecordedSnapshot] = []
    /// Operations whose result we never learned. They stay here until
    /// `queryOutcome` resolves them — silence is not success, and the
    /// only way that stays true is if the uncertainty is durable.
    public var pendingOperations: [PendingOperation] = []
    /// Set while a snapshot waits on a purchase. Its sealed bytes must
    /// survive until the retry resolves.
    public var awaitingPayment: PendingPayment?
    public var receipts: [Data] = []

    public struct RecordedSnapshot: Sendable, Equatable, Codable {
        public let digest: String
        public let sealedByteSize: Int
        public let acceptedTermsId: String
        public let uploadedAt: Date
        public var statusRaw: String
    }

    public struct PendingOperation: Sendable, Equatable, Codable {
        public let operationId: String
        public let digest: String
        /// Our own record of the size. Reconciliation rebuilds the
        /// reference from this rather than from whatever an operator
        /// does or does not echo back — a terse answer must not be able
        /// to produce an unbuildable reference.
        public var sealedByteSize: Int?
        public let startedAt: Date
        /// The terms *we* pinned when this went out. Reconciliation
        /// records this rather than the digest an operator echoes back,
        /// so a counterparty cannot rewrite which terms a stored
        /// snapshot was accepted under.
        public var acceptedTermsId: String?
    }

    /// A snapshot the operator refused for payment, kept across launches.
    ///
    /// A purchase routinely outlives the process — StoreKit will happily
    /// resolve one after a relaunch — and without this the retry has
    /// nothing to send. It would re-compose, mint a new salt, and the
    /// person would pay to store the same history a second time.
    public struct PendingPayment: Sendable, Equatable, Codable {
        public let operationId: String
        public let digest: String
        public let sealedByteSize: Int
        public let sealedBytesFilename: String
        public let acceptedTermsId: String
        public let supersedesDigest: String?
        public let supersedesByteSize: Int?
        /// When the snapshot was sealed. Distinct from `refusedAt`: a
        /// resumed snapshot is as old as its contents, not as old as the
        /// refusal.
        public let sealedAt: Date
        public let refusedAt: Date
    }

    public init() {}

    mutating func clearPendingPayment(for operationId: String) {
        if awaitingPayment?.operationId == operationId { awaitingPayment = nil }
    }

    /// Append a retention to the chain, replacing any earlier record of
    /// the same digest so a reconciliation cannot double-count what an
    /// upload already recorded.
    mutating func record(
        reference: SnapshotReference,
        acceptedTermsId: String,
        at date: Date,
        status: BackupOutcomeStatus
    ) {
        snapshots.removeAll { $0.digest == reference.digest }
        snapshots.append(
            RecordedSnapshot(
                digest: reference.digest,
                sealedByteSize: reference.sealedByteSize,
                acceptedTermsId: acceptedTermsId,
                uploadedAt: date,
                statusRaw: status.rawValue
            )
        )
        // Kept in time order, not resolution order. A pending operation
        // resolved later is still *older*, and appending it to the tail
        // would make the next snapshot supersede a stale ancestor.
        snapshots.sort { $0.uploadedAt < $1.uploadedAt }
    }

    /// The snapshot a new one should supersede: the newest by upload
    /// time, which is not necessarily the last one recorded.
    var newestSnapshot: RecordedSnapshot? {
        snapshots.max { $0.uploadedAt < $1.uploadedAt }
    }
}

/// Persists `BackupState`.
public protocol BackupStateStoring: Sendable {
    func load() throws -> BackupState
    func save(_ state: BackupState) throws
}

/// File-backed state under complete protection.
public struct FileBackupStateStore: BackupStateStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> BackupState {
        // Absent is a first run. *Unreadable* is not: an I/O error, or a
        // read attempted while the device is locked and the file is under
        // complete protection, would otherwise return an empty state that
        // the next save writes over the real one — dropping the pinned
        // terms and every pending operation. Exactly what the corrupt
        // branch below refuses, arrived at by a different door.
        guard FileManager.default.fileExists(atPath: url.path) else { return BackupState() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupError.localFailure(reason: .stateUnreadable)
        }
        guard let state = try? JSONDecoder().decode(BackupState.self, from: data) else {
            // A corrupt state file must not read as "no backup
            // configured": that would silently drop the pinned terms and
            // the pending-operation list, and the next upload would go
            // out under terms nobody re-consented to.
            throw BackupError.localFailure(reason: .stateUnreadable)
        }
        return state
    }

    public func save(_ state: BackupState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
