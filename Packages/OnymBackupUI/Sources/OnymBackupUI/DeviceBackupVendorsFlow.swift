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
        case on(operators: Int, lastSuccessAt: Date?)
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
        let statuses = vendors.map(\.flow.state.status)
        let enrolled = statuses.filter { !DeviceBackupSettingsFlow.needsEnrolment(for: $0) }
        guard !enrolled.isEmpty else { return .off(consented: vendors.count) }

        var healthy = 0
        var attention = 0
        var lastSuccess: Date?
        for status in enrolled {
            switch status {
            case .idle(let at):
                healthy += 1
                lastSuccess = [lastSuccess, at].compactMap { $0 }.max()
            case .running:
                healthy += 1
            default:
                // stale, paymentRequired, checkingEarlierBackup, failed.
                // Each of these means this operator is not currently
                // holding what it is supposed to hold.
                attention += 1
            }
        }
        if attention > 0 { return .needsAttention(attention: attention, healthy: healthy) }
        return .on(operators: healthy, lastSuccessAt: lastSuccess)
    }

    /// How many operators hold at least one snapshot right now.
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
        lastRun = await fanOut.backUpAll()
        isRunning = false
        // Each operator's own screen reads its own state file; the
        // fan-out wrote them all.
        refresh()
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
    public func lastResult(for componentId: String) -> BackupFanOut.VendorResult? {
        lastRun.first { $0.componentId == componentId }?.result
    }
}
