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
        /// A different operator is consented to than the one this state
        /// was enrolled with.
        case operatorChanged
        /// Earlier work could not be resolved, so nothing new was
        /// composed. Not a failure — and not success either.
        case checkingEarlierBackup
        case failed(message: String)
    }

    /// Whether the person needs to go through enrolment.
    ///
    /// `.off` alone was not enough, and the gap was the whole point of
    /// the enrolment route: after consenting to a new operator, the
    /// stored terms id from the *old* one is still there, so the status
    /// read as enrolled, the "Set Up Backup" row never appeared, and
    /// every Back Up Now returned `termsChanged` with nowhere to go. A
    /// protection that only runs on first enrolment is not a protection
    /// against switching.
    public var needsEnrolment: Bool { Self.needsEnrolment(for: state.status) }

    /// Pure, so the routing can be checked without a repository — the
    /// previous version of this rule was wrong in a way only a human
    /// clicking through Settings would have found.
    nonisolated public static func needsEnrolment(for status: Status) -> Bool {
        switch status {
        case .off, .termsChanged, .operatorChanged: true
        default: false
        }
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
    /// The operator consented to *now*, which is not necessarily the one
    /// this state was enrolled with.
    private let currentComponentId: @Sendable () -> String?
    private let schedule: BackupSchedule
    /// Drawn once for this flow's lifetime. Re-drawing per check would
    /// let frequent polling sample until it found a small value, which
    /// is the same as no jitter.
    private let sessionJitter: TimeInterval

    public init(
        repository: BackupRepository,
        stateStore: any BackupStateStoring,
        currentComponentId: @escaping @Sendable () -> String? = { nil },
        schedule: BackupSchedule = .default
    ) {
        self.repository = repository
        self.stateStore = stateStore
        self.currentComponentId = currentComponentId
        self.schedule = schedule
        self.sessionJitter = schedule.drawJitter()
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
        // The consented operator moved out from under this state. Nothing
        // recorded here means anything to the new one, so the only honest
        // next step is enrolment.
        // Includes state written before the operator was recorded at
        // all: nil is not "matches", it is "cannot tell", and guessing
        // in favour of proceeding is how a snapshot reaches the wrong
        // operator. Re-enrolment is the cost, and it is one screen.
        if currentComponentId() != stored.componentId {
            state.status = .operatorChanged
            return
        }
        // A snapshot already sealed and refused for payment outranks
        // idle: it is owed a retry, and showing "On" would leave a person
        // who has since paid wondering why nothing happens.
        if stored.awaitingPayment != nil {
            state.status = .paymentRequired(offerIds: [])
            return
        }
        // Unresolved work outranks "on". An upload whose result we never
        // learned survives a relaunch, and rendering it as idle would
        // show uncertainty as success on exactly the screen that exists
        // to prevent that — and would leave the person wondering why
        // Back Up Now does nothing new.
        guard stored.pendingOperations.isEmpty else {
            state.status = .checkingEarlierBackup
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
            // A snapshot refused for payment is retried byte for byte
            // before anything new is composed. Composing instead would
            // mint a fresh salt and digest, so the person would have
            // bought storage for a snapshot that is then never sent —
            // and would be asked to buy again for its replacement.
            if let pending = try await repository.pendingPayment() {
                switch try await repository.retry(pending) {
                case .retained, .alreadyRetained:
                    refresh()
                    return
                case .paymentRequired(_, let offerIds, _):
                    state.status = .paymentRequired(offerIds: offerIds)
                    return
                default:
                    // Anything else — terms moved under it, operator
                    // changed — means this snapshot is not sendable.
                    // `pendingPayment()` has already cleared the record
                    // in those cases, so falling through to compose is
                    // safe rather than leaving a stale one behind.
                    break
                }
            }
            switch try await repository.backUp() {
            case .retained, .alreadyRetained:
                refresh()
            case .paymentRequired(_, let offerIds, _):
                state.status = .paymentRequired(offerIds: offerIds)
            case .termsChanged:
                state.status = .termsChanged
            case .operatorChanged:
                state.status = .operatorChanged
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
        guard schedule.permitsOpportunisticRun(conditions, jitter: sessionJitter) else { return }
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
            // The previous receipt is left alone. It describes an
            // erasure that did happen, and its excludedScope is
            // something a person may need long afterwards — a failure
            // here is not a reason to destroy the record of an earlier
            // success.
            state.status = .failed(message: String(describing: error))
        }
    }
}
