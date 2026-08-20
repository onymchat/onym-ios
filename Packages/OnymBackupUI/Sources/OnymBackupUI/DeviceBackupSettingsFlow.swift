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

    /// Whether this operator is waiting on a purchase.
    public var isPaymentRequired: Bool {
        if case .paymentRequired = state.status { return true }
        return false
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

    /// A sentence about the last run that state alone cannot say.
    ///
    /// Cleared by `refresh()`, so it cannot outlive the run it
    /// describes: a fan-out failure used to sit in the vendors list
    /// beside a later, successful per-operator backup, reading
    /// "backed up today · last run: <last week's error>".
    public private(set) var lastRunNote: String?

    /// The operator this screen is about.
    ///
    /// One flow per operator: a person may keep the same history with
    /// several at once, and each has its own terms pin, its own chain,
    /// its own payment and its own idea of whether it is up to date.
    /// Nothing here aggregates — `DeviceBackupVendorsFlow` does that.
    public let componentId: String
    /// What to call this operator on screen.
    public let displayName: String
    /// This operator was set up with attachments included, and is no
    /// longer getting them.
    ///
    /// One archive is composed for every operator, so its media policy
    /// is the strictest any of them was consented under. That is the
    /// right direction to be wrong in — nobody receives more than they
    /// were agreed to — but it narrows what an already-enrolled operator
    /// gets, without anything having changed on its own screen. Silently
    /// dropping attachments from an operator someone chose *for*
    /// attachments is the kind of quiet downgrade this seat says it does
    /// not do.
    public let attachmentsWithheld: Bool

    /// What happened the last time someone asked to leave this
    /// operator, if it did not simply work.
    public private(set) var stopFailure: String?

    private let repository: BackupRepository
    private let stateStore: any BackupStateStoring
    private let schedule: BackupSchedule
    /// Withdraws consent and forgets this operator. Supplied by the
    /// composition root, which owns the consent store; `nil` in a build
    /// that does not offer leaving.
    private let onStopBackingUp: (@MainActor @Sendable () -> Void)?
    /// Drawn once for this flow's lifetime. Re-drawing per check would
    /// let frequent polling sample until it found a small value, which
    /// is the same as no jitter.
    private let sessionJitter: TimeInterval

    public init(
        componentId: String,
        displayName: String,
        repository: BackupRepository,
        stateStore: any BackupStateStoring,
        schedule: BackupSchedule = .default,
        attachmentsWithheld: Bool = false,
        onStopBackingUp: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.componentId = componentId
        self.displayName = displayName
        self.attachmentsWithheld = attachmentsWithheld
        self.onStopBackingUp = onStopBackingUp
        self.repository = repository
        self.stateStore = stateStore
        self.schedule = schedule
        self.sessionJitter = schedule.drawJitter()
    }

    public func refresh() {
        lastRunNote = nil
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
        // This state does not belong to the operator this screen is
        // about. With one state file per operator that means state
        // written before the operator was recorded at all. `nil` is not
        // "matches", it is "cannot tell", and guessing in favour of
        // proceeding is how a snapshot reaches the wrong operator.
        // Re-enrolment is the cost, and it is one screen.
        if stored.componentId != componentId {
            state.status = .operatorChanged
            return
        }
        // A refusal recorded by the last run outranks everything below
        // it, including a pending payment: an operator that has stopped
        // accepting uploads is not idle however recent its last
        // success, and a purchase made before the terms moved buys
        // nothing until somebody has read them. This is the state that
        // routes to the screen where they can.
        switch stored.lastBlockedReason {
        case .termsChanged:
            state.status = .termsChanged
            return
        case .operatorChanged:
            state.status = .operatorChanged
            return
        case nil:
            break
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
    /// Show this operator as busy while somebody else's run covers it.
    ///
    /// A fan-out drives the repositories directly, so without this the
    /// per-operator screen reads `.idle` for minutes while its snapshot
    /// is being sealed — and its Back Up Now, whose only guard is that
    /// status, is tappable.
    public func markRunning() {
        state.status = .running
        lastRunNote = nil
    }

    public func backUpNow() async {
        state.status = .running
        lastRunNote = nil
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
            let result = try await repository.backUp()
            if case .alreadyRunning = result {
                state.status = .running
            } else {
                apply(result)
            }
        } catch {
            state.status = .failed(message: BackupCopy.describe(error))
        }
    }

    /// Take on the result of a run this flow did not make.
    ///
    /// A fan-out drives the repositories directly, so its results never
    /// pass through here — and most of what a run can report is not
    /// written to local state at all. `termsChanged` and
    /// `operatorChanged` in particular stop uploads without recording
    /// anything, so `refresh()` alone reads the state of a device that
    /// last backed up successfully and says "On". An operator that has
    /// stopped accepting uploads until somebody re-reads its terms would
    /// show as healthy until it happened to go stale, with no route to
    /// the screen that fixes it.
    ///
    /// So the run tells the flow what it learned. Only downwards:
    /// `retained` re-reads state rather than asserting success from a
    /// return value.
    public func apply(_ result: BackupRepository.RunResult, resumedPayment: Bool = false) {
        switch result {
        case .retained, .alreadyRetained:
            refresh()
            if resumedPayment {
                // It backed up, and not the same thing the others got.
                lastRunNote = "The backup you paid for went up; the newest changes go next time."
            }
        case .paymentRequired(_, let offerIds, _):
            state.status = .paymentRequired(offerIds: offerIds)
        case .termsChanged:
            state.status = .termsChanged
        case .operatorChanged:
            state.status = .operatorChanged
        case .awaitingReconciliation:
            state.status = .checkingEarlierBackup
        case .unknown:
            // Never rendered as success. The bytes may be held; only the
            // operator can say, and it has not — but *how* that is
            // rendered comes from the state file, which recorded a
            // pending operation before the upload and therefore reads as
            // "checking an earlier backup". Overwriting that with
            // "something went wrong" gave one unchanged state two
            // different words and two different icons depending on which
            // screen you were looking at, with the alarming one on the
            // summary.
            refresh()
            if case .idle = state.status {
                state.status = .failed(message: "The result of the last backup is still unknown.")
            }
            if case .stale = state.status {
                state.status = .failed(message: "The result of the last backup is still unknown.")
            }
        case .alreadyRunning:
            break
        }
    }

    /// A credential arrived for an operator that is waiting on one.
    ///
    /// The status stays `paymentRequired`, because it is derived from a
    /// snapshot still sitting unsent — a credential does not place those
    /// bytes, only a run does. Saying so beats a screen that keeps
    /// reading "Payment needed" with no explanation after someone has
    /// just restored the purchase it was asking for.
    public func noteRestoredPurchase() {
        lastRunNote = "Purchase restored — tap Back Up Now to finish this backup."
    }

    /// Report that a run threw before it could reach a result.
    public func applyFailure(message: String) {
        state.status = .failed(message: message)
        lastRunNote = message
    }

    /// Run only if the schedule permits it — the opportunistic path.
    public func backUpIfDue(conditions: BackupSchedule.Conditions) async {
        guard schedule.permitsOpportunisticRun(conditions, jitter: sessionJitter) else { return }
        await backUpNow()
    }

    public func loadSnapshots() async {
        state.snapshots = (try? await repository.listSnapshots()) ?? []
    }

    public var canStopBackingUp: Bool { onStopBackingUp != nil }

    /// Stop backing up to this operator.
    ///
    /// The route out that did not exist. Consenting to a second operator
    /// adds one rather than replacing the first — that is the whole
    /// point of the seat — so without this, every operator a person ever
    /// chose keeps receiving their history and keeps charging for it,
    /// and the only way to stop is to delete the app.
    ///
    /// `erasingFirst` asks the operator to destroy what it holds and
    /// keeps the receipt. It is offered rather than assumed: erasure is
    /// a request to a counterparty that can fail or be refused, and
    /// someone who wants to stop paying today should not be blocked by
    /// an operator that will not answer. What is *not* offered is
    /// pretending: a failed erasure says so and leaves the choice of
    /// stopping anyway to the person.
    ///
    /// Local state goes either way. It describes a relationship that has
    /// ended — except the receipts, which are evidence of something that
    /// happened and are the one thing kept.
    public func stopBackingUp(erasingFirst: Bool) async {
        stopFailure = nil
        if erasingFirst {
            do {
                state.lastReceipt = try await repository.erase(scope: .all)
            } catch {
                // Not stopped, and not erased. Saying so beats reporting
                // either one as done.
                stopFailure = """
                    \(displayName) did not confirm that it erased your backup, so nothing was \
                    changed. You can try again, or stop without erasing — what it already holds \
                    stays until its own retention period ends.
                    """
                return
            }
        }
        do {
            var cleared = BackupState()
            // Receipts survive. They record what an erasure did and did
            // not reach, they are never acted on, and destroying them
            // because a relationship ended would discard the only
            // durable evidence of it.
            cleared.receipts = ((try? stateStore.load())?.receipts ?? [])
            try stateStore.save(cleared)
        } catch {
            stopFailure = "This device could not update its backup settings, so nothing was changed."
            return
        }
        state.status = .off
        lastRunNote = nil
        onStopBackingUp?()
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
            state.status = .failed(message: BackupCopy.describe(error))
        }
    }
}
