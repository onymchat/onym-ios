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
        public let startedAt: Date
    }

    public init() {}
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
        guard let data = try? Data(contentsOf: url) else { return BackupState() }
        guard let state = try? JSONDecoder().decode(BackupState.self, from: data) else {
            // A corrupt state file must not read as "no backup
            // configured": that would silently drop the pinned terms and
            // the pending-operation list, and the next upload would go
            // out under terms nobody re-consented to.
            throw BackupError.localFailure(reason: .archiveUnreadable)
        }
        return state
    }

    public func save(_ state: BackupState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
