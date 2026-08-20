import Foundation
import OnymBackup

/// Backs Settings → Device Backup.
///
/// Holds no policy of its own: what a backup means, when one may run,
/// and what an outcome is called all live below. This turns those into
/// something a view can render, and — the part that matters — renders
/// uncertainty as uncertainty.
@MainActor
@Observable
public final class DeviceBackupSettingsFlow {
    public enum Status: Equatable {
        /// Never enrolled. The only state a person starts in.
        case off
        case idle(lastSuccessAt: Date?)
        case running
        /// No successful backup for longer than the schedule allows.
        /// Shown as a state rather than left to look like "on".
        case stale(lastSuccessAt: Date?)
        /// The operator wants payment before it will take a snapshot.
        case paymentRequired(offerIds: [String])
        /// The operator published new terms. Uploads stop until they
        /// have been seen and accepted.
        case termsChanged
        /// Earlier work could not be resolved, so nothing new was
        /// composed. Not a failure — and not success either.
        case checkingEarlierBackup
        case failed(message: String)
    }

    public struct State: Equatable {
        public var status: Status = .off
        public var snapshots: [RetainedSnapshot] = []
        public var lastReceipt: ErasureReceipt?
        /// Content addresses a restore could not resolve. Surfaced
        /// because partially-missing media is something a person should
        /// hear from us rather than discover.
        public var unresolvedMedia: [String] = []
    }

    public private(set) var state = State()

    private let repository: BackupRepository
    private let stateStore: any BackupStateStoring
    private let schedule: BackupSchedule

    public init(
        repository: BackupRepository,
        stateStore: any BackupStateStoring,
        schedule: BackupSchedule = .default
    ) {
        self.repository = repository
        self.stateStore = stateStore
        self.schedule = schedule
    }

    public func refresh() {
        guard let stored = try? stateStore.load() else {
            // An unreadable state file is not "no backup configured".
            // Saying so would invite someone to enrol again on top of
            // an enrolment that already exists.
            state.status = .failed(message: "Backup settings could not be read.")
            return
        }
        guard stored.acceptedTermsId != nil else {
            state.status = .off
            return
        }
        state.status = schedule.isStale(lastSuccessAt: stored.lastSuccessAt)
            ? .stale(lastSuccessAt: stored.lastSuccessAt)
            : .idle(lastSuccessAt: stored.lastSuccessAt)
    }

    /// Run a backup the person asked for.
    ///
    /// An explicit request bypasses the schedule entirely — someone who
    /// taps the button has already decided the upload is worth it, and
    /// second-guessing them about battery would be presumptuous.
    public func backUpNow() async {
        state.status = .running
        do {
            switch try await repository.backUp() {
            case .retained, .alreadyRetained:
                refresh()
            case .paymentRequired(_, let offerIds, _):
                state.status = .paymentRequired(offerIds: offerIds)
            case .termsChanged:
                state.status = .termsChanged
            case .awaitingReconciliation:
                state.status = .checkingEarlierBackup
            case .unknown:
                // Never rendered as success. The bytes may be held; only
                // the operator can say, and it has not.
                state.status = .failed(
                    message: "The result of the last backup is still unknown.")
            case .alreadyRunning:
                state.status = .running
            }
        } catch {
            state.status = .failed(message: String(describing: error))
        }
    }

    /// Run only if the schedule permits it — the opportunistic path.
    public func backUpIfDue(conditions: BackupSchedule.Conditions) async {
        guard schedule.permitsOpportunisticRun(conditions) else { return }
        await backUpNow()
    }

    public func loadSnapshots() async {
        state.snapshots = (try? await repository.listSnapshots()) ?? []
    }

    /// Erase, and keep the receipt.
    ///
    /// The receipt is retained rather than discarded after display: its
    /// `excludedScope` is what an erasure did *not* reach, and a person
    /// may want it later.
    public func erase(scope: ErasureScope) async {
        do {
            state.lastReceipt = try await repository.erase(scope: scope)
            await loadSnapshots()
        } catch {
            state.lastReceipt = nil
            state.status = .failed(message: String(describing: error))
        }
    }
}
