import Foundation
import OnymBackup

/// Turning backup on.
///
/// Two steps, and the order is the whole point: fetch and verify what
/// the operator published, then — only if a person accepts it — write
/// the pin that every future snapshot will carry. Nothing is uploaded
/// here, and nothing is enabled by arriving at the screen.
@MainActor
@Observable
public final class BackupEnrolmentFlow {
    public enum State: Equatable {
        case loading
        /// Terms fetched and verified; waiting on a decision.
        case ready(BackupDisclosure)
        /// The operator's terms could not be fetched or did not verify.
        /// Enrolment stops: terms are a precondition, not a nicety, and
        /// enrolling without them would pin nothing.
        case unavailable(message: String)
        case enrolled
    }

    public private(set) var state: State = .loading

    private let port: any BackupPort
    private let stateStore: any BackupStateStoring
    private let schedule: BackupSchedule
    private let mediaPolicy: BackupMediaPolicy
    private let workingDirectory: URL
    private var connection: BackupConnection?

    public init(
        port: any BackupPort,
        stateStore: any BackupStateStoring,
        workingDirectory: URL,
        schedule: BackupSchedule = .default,
        mediaPolicy: BackupMediaPolicy = .descriptorsOnly
    ) {
        self.port = port
        self.stateStore = stateStore
        self.workingDirectory = workingDirectory
        self.schedule = schedule
        self.mediaPolicy = mediaPolicy
    }

    public func load() async {
        state = .loading
        do {
            let connection = try await port.connect()
            self.connection = connection
            state = .ready(
                BackupDisclosure.from(
                    connection: connection,
                    schedule: schedule,
                    mediaPolicy: mediaPolicy))
        } catch {
            self.connection = nil
            state = .unavailable(message: String(describing: error))
        }
    }

    /// Record the consent.
    ///
    /// Writes the terms digest the person just read, so every snapshot
    /// pins it and a later change stops uploads until they have seen the
    /// new one. Refuses if the connection is gone — accepting terms we
    /// no longer hold would pin a digest nobody was shown.
    public func accept() {
        guard let connection else {
            state = .unavailable(message: "The operator's terms are no longer available.")
            return
        }
        do {
            var stored = try stateStore.load()
            // Enrolling with a *different* operator discards the
            // previous one's operational state. Keeping it would let
            // reconciliation ask the new operator about the old one's
            // operations, and would let a snapshot awaiting payment —
            // sealed under terms the new operator never published — be
            // retried against it.
            let orphaned = stored.rebind(to: connection.manifest.componentId)
            stored.acceptedTermsId = connection.acceptedTermsId
            stored.acceptedTermsRaw = connection.terms.rawBytes
            stored.mediaPolicy = mediaPolicy
            try stateStore.save(stored)
            if let orphaned {
                // Sealed bytes nobody will claim now. Ciphertext, so not
                // a disclosure — but a file the person never sees and
                // would otherwise keep paying for in storage.
                try? FileManager.default.removeItem(
                    at: workingDirectory.appending(path: orphaned))
            }
            state = .enrolled
        } catch {
            // Not enrolled. Reporting success over a failed write would
            // leave someone believing their history is being backed up
            // when nothing is pinned.
            state = .unavailable(message: String(describing: error))
        }
    }
}
