import CryptoKit
import Foundation

/// Where one operator's local backup state lives.
///
/// A person may keep the same history with more than one operator at
/// once, and nothing about those enrolments is shared: each pins its own
/// terms, holds its own chain, reconciles its own operations and is paid
/// for separately. Two operators sharing one state file would mean an
/// enrolment with the second silently discarding the first's chain — the
/// `rebind` that is correct for *switching* operators is exactly wrong
/// for *adding* one.
///
/// So state is per operator, in its own file, and the operator is part of
/// the filename rather than a field inside it.
public enum BackupVendorStorage {
    /// The single-operator filename, from before more than one was
    /// possible.
    public static let legacyStateFilename = "state.json"

    /// `state-<32 hex>.json`.
    ///
    /// A digest rather than the componentId itself: a componentId is a
    /// URN with colons in it, and the set of operators a person keeps
    /// backups with should not be readable from a directory listing by
    /// anyone who gets as far as the container.
    public static func stateFilename(componentId: String) -> String {
        let digest = SHA256.hash(data: Data(("onym-backup-vendor-v1|" + componentId).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "state-\(hex.prefix(32)).json"
    }

    public static func stateURL(componentId: String, in directory: URL) -> URL {
        directory.appending(path: stateFilename(componentId: componentId))
    }

    public static func stateStore(
        componentId: String,
        in directory: URL
    ) -> FileBackupStateStore {
        FileBackupStateStore(url: stateURL(componentId: componentId, in: directory))
    }

    /// Move a single-operator install's `state.json` onto the per-operator
    /// path, once.
    ///
    /// Without this, the first launch after this change reads no state for
    /// the operator a person is already enrolled with: backup would show
    /// as off, an enrolment screen would appear for something already set
    /// up, and the next snapshot would supersede nothing — the operator
    /// would be paid to store a second copy of a history it already holds.
    ///
    /// A legacy file whose `componentId` is `nil` is left where it is.
    /// It was written before the operator was recorded at all, so there is
    /// no operator to attribute it to; the surfaces already treat that
    /// state as "cannot tell" and route to enrolment, and inventing an
    /// attribution here would be the guess those surfaces refuse to make.
    ///
    /// Returns the componentId migrated, if any.
    @discardableResult
    public static func migrateLegacyState(in directory: URL) -> String? {
        let legacy = directory.appending(path: legacyStateFilename)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        guard
            let data = try? Data(contentsOf: legacy),
            let state = try? JSONDecoder().decode(BackupState.self, from: data),
            let componentId = state.componentId
        else {
            // Unreadable, or unattributable. Either way: leave it alone.
            // Deleting it would destroy erasure receipts, which are
            // evidence of something that happened and are never
            // reconstructible.
            return nil
        }
        let destination = stateURL(componentId: componentId, in: directory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            // Already migrated, and the per-operator file is the live
            // one. The legacy file is a stale copy; removing it keeps a
            // second, older answer from ever being read.
            try? FileManager.default.removeItem(at: legacy)
            return componentId
        }
        do {
            try FileManager.default.moveItem(at: legacy, to: destination)
        } catch {
            // A failed move must not read as a migration: returning the
            // componentId would tell the caller a file exists that does
            // not, and the enrolment it describes would look lost. The
            // legacy file stays, and the next launch tries again.
            return nil
        }
        return componentId
    }
}
