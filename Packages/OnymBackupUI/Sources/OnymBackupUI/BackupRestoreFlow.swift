import Foundation
import OnymBackup

/// Restoring history from a snapshot.
///
/// **This does not restore an identity and does not wipe one.** The two
/// are separate and it is worth being precise, because conflating them
/// is how a restore screen becomes dangerous:
///
/// - *Identity* restore replaces the keys this device holds, wiping
///   every existing identity. It lives in onboarding, where nothing is
///   at stake, and is not reachable from here.
/// - *History* restore — this — derives its key from the identity the
///   device already has and writes messages and groups through the app's
///   own stores. Nothing is replaced, nothing is deleted; a restored row
///   that already exists is updated in place.
///
/// So someone moving to a new phone restores their identity from the
/// recovery phrase during onboarding, chooses their backup operator, and
/// then comes here for their history.
///
/// It reads from every operator the person keeps backups with, not one.
/// Each operator sealed its own copy with its own salt, so their
/// snapshots are separate rows with separate references — a copy is not
/// interchangeable with another copy on the wire, only in what it
/// contains. That is the point of keeping two: if one operator cannot be
/// reached, or its copy will not open, the other's is a different set of
/// bytes and may well do.
/// One operator a restore may read from.
public struct BackupRestoreSource: Sendable {
    public let componentId: String
    public let displayName: String
    public let repository: BackupRepository

    public init(componentId: String, displayName: String, repository: BackupRepository) {
        self.componentId = componentId
        self.displayName = displayName
        self.repository = repository
    }
}

/// One snapshot, and which operator is holding it.
///
/// The operator is part of the row rather than a filter above the list
/// because it is part of the choice: these are different bytes in
/// different jurisdictions, taken at different moments, and which one a
/// person restores from is a decision only they can make.
public struct RestorableSnapshot: Identifiable, Equatable, Sendable {
    public let snapshot: RetainedSnapshot
    public let componentId: String
    public let operatorName: String

    public var id: String { componentId + "|" + snapshot.snapshotReference.digest }

    public init(snapshot: RetainedSnapshot, componentId: String, operatorName: String) {
        self.snapshot = snapshot
        self.componentId = componentId
        self.operatorName = operatorName
    }
}

@MainActor
@Observable
public final class BackupRestoreFlow {
    public enum State: Equatable {
        case loading
        /// What the operators hold for this holder key. Empty is an
        /// ordinary answer — a different operator, or a different
        /// identity, has a different holder key and sees nothing.
        case ready(snapshots: [RestorableSnapshot])
        case restoring(SnapshotReference)
        case restored(BackupRestoreSummary)
        /// `partial` is true when writing had already begun, so the
        /// screen must not promise that nothing changed.
        case failed(message: String, partial: Bool)
    }

    public private(set) var state: State = .loading
    /// Operators that could not be listed, by name. Named rather than
    /// swallowed: a person deciding whether their history is recoverable
    /// should not be shown a short list that looks complete.
    public private(set) var unreachableOperators: [String] = []

    private let sources: [BackupRestoreSource]
    private let restorer: BackupRestorer
    private let keyMaterial: BackupKeyMaterial
    private let workingDirectory: URL

    public init(
        sources: [BackupRestoreSource],
        restorer: BackupRestorer,
        keyMaterial: BackupKeyMaterial,
        workingDirectory: URL
    ) {
        self.sources = sources
        self.restorer = restorer
        self.keyMaterial = keyMaterial
        self.workingDirectory = workingDirectory
    }

    public func load() async {
        state = .loading
        unreachableOperators = []
        var rows: [RestorableSnapshot] = []
        var unreachable: [String] = []
        for source in sources {
            do {
                let snapshots = try await source.repository.listSnapshots()
                rows += snapshots.map {
                    RestorableSnapshot(
                        snapshot: $0,
                        componentId: source.componentId,
                        operatorName: source.displayName)
                }
            } catch {
                // One operator being unreachable is not a failed
                // restore screen — the others may be holding exactly
                // what this person needs. It is also not nothing, so it
                // is named.
                unreachable.append(source.displayName)
            }
        }
        unreachableOperators = unreachable
        if rows.isEmpty, !sources.isEmpty, unreachable.count == sources.count {
            // Nothing answered. Reporting "no backups" here would tell
            // someone their history is gone on the evidence of a network
            // failure.
            state = .failed(
                message: "No backup operator could be reached, so what they hold is unknown.",
                partial: false)
            return
        }
        // Newest first, across operators: the one a person almost always
        // wants is the last one taken, and making them read dates to find
        // it is work the screen can do.
        state = .ready(snapshots: rows.sorted { $0.snapshot.retainedAt > $1.snapshot.retainedAt })
    }

    /// Download, verify, and apply one snapshot, from the operator that
    /// holds it.
    public func restore(_ row: RestorableSnapshot) async {
        guard let source = sources.first(where: { $0.componentId == row.componentId }) else {
            state = .failed(
                message: "That backup's operator is no longer set up on this device.",
                partial: false)
            return
        }
        let reference = row.snapshot.snapshotReference
        state = .restoring(reference)
        // `sealed-`, not `restore-`. The restorer decrypts to
        // `restore-<digest>` in this same directory, so the two used to
        // be the identical path: `BackupOpener` would hold a read handle
        // on the sealed file and create the plaintext over it. Whether
        // that works at all depends on whether Foundation replaces the
        // inode or truncates in place — on truncate semantics every
        // restore fails as `incompleteSnapshot`.
        let downloaded = workingDirectory.appending(path: "sealed-\(reference.digestHex)")
        defer { try? FileManager.default.removeItem(at: downloaded) }

        do {
            try await source.repository.download(reference, to: downloaded)
            let summary = try await restorer.restore(
                sealedURL: downloaded,
                reference: reference,
                keyMaterial: keyMaterial,
                workingDirectory: workingDirectory
            )
            state = .restored(summary)
        } catch {
            // Nothing partial has been written: the restorer verifies the
            // whole reference and decodes the entire archive before it
            // touches a store. A failure here means the device is exactly
            // as it was.
            // Everything up to the write phase leaves the device
            // untouched — the reference is verified and the whole
            // archive decoded before a store is opened. Past that
            // point the restorer says so, and so do we.
            let partial: Bool
            if case BackupError.localFailure(.restoreInterrupted) = error {
                partial = true
            } else {
                partial = false
            }
            state = .failed(message: Self.describe(error), partial: partial)
        }
    }

    /// A sentence, not a debug description.
    ///
    /// `String(describing:)` on a `BackupError` produces things like
    /// `incompleteSnapshot` or a `URLError` dump — accurate, and useless
    /// to someone halfway through restoring their messages. The raw
    /// value is still worth keeping for a log; it is the screen that
    /// needs plain words.
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case BackupError.incompleteSnapshot:
            return "The backup did not arrive complete, so nothing was restored."
        case BackupError.retentionExpired:
            return "The operator no longer holds this backup."
        case BackupError.accessRefused:
            return "The operator did not accept this device's key."
        case BackupError.operatorUnavailable:
            return "The operator could not be reached. Nothing was changed."
        case BackupError.localFailure(.stateUnreadable),
             BackupError.localFailure(.archiveUnreadable):
            return "The backup could not be read on this device."
        case BackupError.localFailure(.restoreInterrupted):
            return "The restore stopped partway. Some items may already have been added — restoring again is safe and will finish the job."
        case BackupError.localFailure(.noRecoveryPhrase):
            return "This identity has no recovery phrase, so it has no backups to restore."
        case BackupError.termsUnavailable:
            return "The operator's terms could not be checked, so nothing was restored."
        case let error as BackupError:
            // An operator code we do not model. Its own words beat our
            // guess at what it meant.
            if case .rejected(_, let message) = error, let message {
                return message
            }
            return "The restore did not complete. Nothing on this phone was changed."
        default:
            return "The restore did not complete. Nothing on this phone was changed."
        }
    }
}
