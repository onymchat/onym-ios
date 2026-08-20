import Foundation
import OnymBackup

/// Settings → Device Backup, when there may be more than one operator.
///
/// It aggregates and it routes; it decides nothing. Each operator keeps
/// its own `DeviceBackupSettingsFlow` — its own status, its own payment,
/// its own terms — and this exists so a person can see at a glance how
/// many copies of their history exist and which of them is in trouble,
/// without a screen that averages four different situations into one
/// reassuring word.
///
/// The summary is deliberately pessimistic. "On" here means every
/// enrolled operator is up to date; anything else names the number that
/// are not. A backup surface that rounds up is the one failure mode this
/// whole stack is built to avoid.
@MainActor
@Observable
public final class DeviceBackupVendorsFlow {
    public struct Vendor: Identifiable {
        public let flow: DeviceBackupSettingsFlow
        public var id: String { flow.componentId }
        public var displayName: String { flow.displayName }

        public init(flow: DeviceBackupSettingsFlow) {
            self.flow = flow
        }
    }

    /// The one-line answer, for the status card.
    public enum Summary: Equatable {
        /// Operators are consented to, but none has been set up.
        case off(consented: Int)
        /// Every enrolled operator is holding a current backup.
        /// `notSetUp` is still reported, because a consented operator
        /// holding nothing is not covered by the ones that are.
        case on(operators: Int, notSetUp: Int, lastSuccessAt: Date?)
        case running
        /// Some operators are fine and some are not. `attention` is
        /// never folded into `on`, however small it is.
        case needsAttention(attention: Int, healthy: Int)
    }

    public private(set) var vendors: [Vendor]
    public private(set) var isRunning = false
    /// The last fan-out's per-operator results, newest run only. Shown
    /// beneath the list so a run that half-worked reads as a run that
    /// half-worked.
    public private(set) var lastRun: [BackupFanOut.Outcome] = []

    private let fanOut: BackupFanOut
    private let schedule: BackupSchedule
    private let sessionJitter: TimeInterval

    public init(
        vendors: [Vendor],
        fanOut: BackupFanOut,
        schedule: BackupSchedule = .default
    ) {
        self.vendors = vendors
        self.fanOut = fanOut
        self.schedule = schedule
        self.sessionJitter = schedule.drawJitter()
    }

    public var summary: Summary {
        if isRunning { return .running }

        var healthy = 0
        var attention = 0
        var notSetUp = 0
        var running = 0
        var lastSuccess: Date?
        for vendor in vendors {
            switch vendor.flow.state.status {
            case .off:
                notSetUp += 1
            case .idle(let at):
                healthy += 1
                // The *oldest* success, not the newest. Two operators,
                // one an hour old and one six days old, are not both an
                // hour old — and the number a person reads as "how far
                // back am I exposed" is the older one.
                lastSuccess = [lastSuccess, at].compactMap { $0 }.min()
            case .running:
                // Somebody else's run, or this operator's own. In
                // flight is not up to date: it may never have retained
                // anything.
                running += 1
            case .stale, .paymentRequired, .termsChanged, .operatorChanged,
                 .checkingEarlierBackup, .failed:
                // Every one of these means this operator is not
                // currently holding what it is supposed to hold.
                // `termsChanged` and `operatorChanged` are counted here
                // rather than folded in with "not set up": uploads have
                // stopped at an operator that *is* set up, and calling
                // that Off would read as a choice the person made.
                attention += 1
            }
        }
        if running > 0 { return .running }
        if attention > 0 { return .needsAttention(attention: attention, healthy: healthy) }
        if healthy > 0 {
            return .on(operators: healthy, notSetUp: notSetUp, lastSuccessAt: lastSuccess)
        }
        return .off(consented: notSetUp)
    }

    /// How many operators are set up — that is, are not waiting on
    /// enrolment, new terms, or a re-enrolment. Not the same as how many
    /// hold a snapshot: one set up a minute ago holds nothing yet.
    public var enrolledCount: Int {
        vendors.filter { !DeviceBackupSettingsFlow.needsEnrolment(for: $0.flow.state.status) }.count
    }

    public func refresh() {
        for vendor in vendors { vendor.flow.refresh() }
    }

    public func loadSnapshots() async {
        for vendor in vendors { await vendor.flow.loadSnapshots() }
    }

    /// Back up to every enrolled operator.
    ///
    /// One run of the history, one seal per operator. A person who set up
    /// two operators asked for two copies, and a button that quietly sent
    /// to whichever one answered first would be giving them one.
    public func backUpAllNow() async {
        guard !isRunning else { return }
        isRunning = true
        // Every operator that could be part of this run shows as busy
        // for its duration, so its own screen cannot offer a second
        // Back Up Now over the top of it.
        for vendor in vendors where !DeviceBackupSettingsFlow.needsEnrolment(
            for: vendor.flow.state.status) {
            vendor.flow.markRunning()
        }
        let outcomes = await fanOut.backUpAll()
        lastRun = outcomes
        isRunning = false
        // Each operator's own screen reads its own state file; the
        // fan-out wrote them all.
        refresh()
        // And then what the state files cannot say. A run blocked on new
        // terms or a changed operator writes nothing, so a refresh alone
        // would show the last successful backup and call it On — for an
        // operator that has stopped accepting uploads.
        for outcome in outcomes {
            guard let vendor = vendors.first(where: { $0.id == outcome.componentId }) else { continue }
            switch outcome.result {
            case .ran(let result):
                vendor.flow.apply(result, resumedPayment: outcome.resumedPayment)
            case .failed(let message): vendor.flow.applyFailure(message: message)
            }
        }
    }

    /// The opportunistic path: run only if the schedule permits it.
    ///
    /// Checked once for the device rather than once per operator. The
    /// schedule is about this phone's battery and network, which are not
    /// facts about an operator.
    public func backUpIfDue(conditions: BackupSchedule.Conditions) async {
        guard schedule.permitsOpportunisticRun(conditions, jitter: sessionJitter) else { return }
        await backUpAllNow()
    }

    /// What one operator reported in the last run, if it reported
    /// anything.
    public func lastRun(for componentId: String) -> BackupFanOut.Outcome? {
        lastRun.first { $0.componentId == componentId }
    }
}
