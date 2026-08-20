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
@MainActor
@Observable
public final class BackupRestoreFlow {
    public enum State: Equatable {
        case loading
        /// What the operator holds for this holder key. Empty is an
        /// ordinary answer — a different operator, or a different
        /// identity, has a different holder key and sees nothing.
        case ready(snapshots: [RetainedSnapshot])
        case restoring(SnapshotReference)
        case restored(BackupRestoreSummary)
        case failed(message: String)
    }

    public private(set) var state: State = .loading

    private let repository: BackupRepository
    private let restorer: BackupRestorer
    private let keyMaterial: BackupKeyMaterial
    private let workingDirectory: URL

    public init(
        repository: BackupRepository,
        restorer: BackupRestorer,
        keyMaterial: BackupKeyMaterial,
        workingDirectory: URL
    ) {
        self.repository = repository
        self.restorer = restorer
        self.keyMaterial = keyMaterial
        self.workingDirectory = workingDirectory
    }

    public func load() async {
        state = .loading
        do {
            let snapshots = try await repository.listSnapshots()
            // Newest first: the one a person almost always wants is the
            // last one taken, and making them read dates to find it is
            // work the screen can do.
            state = .ready(snapshots: snapshots.sorted { $0.retainedAt > $1.retainedAt })
        } catch {
            state = .failed(message: String(describing: error))
        }
    }

    /// Download, verify, and apply one snapshot.
    public func restore(_ snapshot: RetainedSnapshot) async {
        let reference = snapshot.snapshotReference
        state = .restoring(reference)
        let downloaded = workingDirectory.appending(path: "restore-\(reference.digestHex)")
        defer { try? FileManager.default.removeItem(at: downloaded) }

        do {
            try await repository.download(reference, to: downloaded)
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
            state = .failed(message: String(describing: error))
        }
    }
}
