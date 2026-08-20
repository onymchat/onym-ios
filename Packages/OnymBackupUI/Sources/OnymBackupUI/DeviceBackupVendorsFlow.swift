import Foundation
import OnymBackup
import OnymBilling

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

    /// What a restore-purchases sweep reported, per operator.
    public private(set) var purchaseRestore: PurchaseRestore = .idle
    /// Whether the quiet sweep has already run for this flow.
    private var hasSweptPurchases = false

    public enum PurchaseRestore: Equatable {
        case idle
        case running
        /// `restored` counts credentials this device did not have
        /// before; `held` counts the ones it already had. They are
        /// separate because "nothing to restore" and "already set up"
        /// are different answers, and only one of them means something
        /// went wrong.
        /// `checked` is how many operators were actually asked about.
        /// Zero means nothing was, which is not a fact about the App
        /// Store.
        /// `heldUnknown` means this phone could not check what it
        /// already holds — different from finding nothing, and not
        /// something to report as an answer about the App Store.
        /// `syncFailed` means the account-wide sync did not happen or
        /// did not work, so nothing here is an answer about what the
        /// App Store holds.
        case finished(
            restored: Int,
            held: Int,
            checked: Int,
            heldUnknown: Bool,
            syncFailed: Bool,
            failures: [String])
    }

    private let fanOut: BackupFanOut
    private let schedule: BackupSchedule
    private let sessionJitter: TimeInterval
    /// Recovers credentials for purchases made on another device, per
    /// operator. `nil` when this build cannot sell anything — a free
    /// operator, or a build with no store products — in which case the
    /// row does not appear.
    /// Recovers a credential for one operator. `nil` from the closure
    /// means this operator was not checked at all — no pinned issuer, or
    /// nothing this build can sell for it — which is not the same answer
    /// as "the store has nothing".
    private let restorePurchasesForOperator:
        (@Sendable (String) async -> SeatPurchaseFlow.RestoreResult?)?
    /// Asks StoreKit to sync. Account-wide, and prompts for an App
    /// Store password, so it happens once per tap and never per
    /// operator — and it reports whether it worked, because a sweep
    /// that follows a failed sync must not go on to say the App Store
    /// has nothing.
    private let syncPurchasesWithStore: (@Sendable () async -> Bool)?
    /// Guards the sweep itself, rather than what the screen is showing.
    /// The quiet sweep displays nothing, so a status-based guard did not
    /// hold it — and a tap during one started a second concurrent sweep,
    /// with its own `AppStore.sync()`.
    private var isSweepingPurchases = false

    public init(
        vendors: [Vendor],
        fanOut: BackupFanOut,
        schedule: BackupSchedule = .default,
        restorePurchasesForOperator:
            (@Sendable (String) async -> SeatPurchaseFlow.RestoreResult?)? = nil,
        syncPurchasesWithStore: (@Sendable () async -> Bool)? = nil
    ) {
        self.vendors = vendors
        self.fanOut = fanOut
        self.schedule = schedule
        self.sessionJitter = schedule.drawJitter()
        self.restorePurchasesForOperator = restorePurchasesForOperator
        self.syncPurchasesWithStore = syncPurchasesWithStore
    }

    public var canRestorePurchases: Bool { restorePurchasesForOperator != nil }

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

    /// Recover what was already paid for, for every operator.
    ///
    /// The new-phone path. Someone who restored their identity from the
    /// recovery phrase has the keys to prove who they are to the broker
    /// and to open a snapshot, but no credential — the purchase was
    /// finished on a phone they no longer have. Without this the only
    /// route past a paid operator's refusal is to buy the same thing
    /// again.
    ///
    /// `syncWithStore` asks StoreKit to sync first, which prompts for an
    /// App Store password. Passed as false for the sweep that runs on
    /// its own, true for the button someone taps.
    public func restorePurchases(syncWithStore: Bool = true) async {
        await restorePurchases(syncWithStore: syncWithStore, announcingNothingFound: true)
    }

    /// The quiet sweep, once per screen.
    ///
    /// Costs nothing when there is nothing to do: `currentEntitlement`
    /// is answered from what the device already holds, and the broker is
    /// contacted only for a purchase the store knows about and this
    /// device has no credential for. After the first success it
    /// short-circuits on the credential it just stored.
    ///
    /// It runs without being asked because the person it exists for does
    /// not know to ask: on a new phone nothing has been uploaded, so no
    /// operator has refused anything yet, and the refusal that would
    /// have mentioned a purchase has not happened.
    public func restorePurchasesIfNeeded() async {
        guard !hasSweptPurchases else { return }
        await restorePurchases(syncWithStore: false, announcingNothingFound: false)
    }

    private func restorePurchases(syncWithStore: Bool, announcingNothingFound: Bool) async {
        guard let restore = restorePurchasesForOperator, !isSweepingPurchases else { return }
        isSweepingPurchases = true
        defer { isSweepingPurchases = false }
        if announcingNothingFound { purchaseRestore = .running }
        // Once, before the loop. `AppStore.sync()` is account-wide and
        // prompts for a password: doing it per operator asked a person
        // with two operators to authenticate twice for one tap, the
        // second time seconds later and out of context.
        // A sync that did not happen is not a sync that found nothing.
        // Skipping it silently — or swallowing its failure — and then
        // reporting "the App Store has no purchase for this identity"
        // is a definitive answer to a question nobody managed to ask,
        // told to the one person who most needs it to be right: someone
        // on a replacement phone.
        var syncFailed = false
        if syncWithStore {
            syncFailed = await syncPurchasesWithStore?() == false
        }

        var restored = 0
        var held = 0
        var checked = 0
        var heldUnknown = false
        var failures: [String] = []
        /// The operators a credential was actually recovered for. A
        /// total is not enough: with two paid operators, one restore and
        /// one failure, a total would tell the operator that got nothing
        /// that its purchase had been restored.
        var restoredFor: Set<String> = []
        for vendor in vendors {
            guard let result = await restore(vendor.id) else {
                // Not checked: no pinned issuer, or nothing this build
                // sells for it. Counting it as checked would let the row
                // say the App Store has nothing to restore without
                // anything having asked the App Store.
                continue
            }
            checked += 1
            restored += result.restored.count
            if !result.restored.isEmpty { restoredFor.insert(vendor.id) }
            held += result.alreadyHeld.count
            // Named by operator: with several set up, "something went
            // wrong" without saying where is not something a person can
            // act on.
            // Sorted by offer id, so two failing offers do not produce
            // a different subtitle on every run — `Dictionary.values`
            // has no order, and the row shows the first one.
            failures += result.failures
                .sorted { $0.key < $1.key }
                .map(\.value)
                .filter { !Self.isCancellation($0) }
                .map { "\(vendor.displayName): \($0)" }
            if result.heldUnknown { heldUnknown = true }
        }

        if Task.isCancelled {
            // The screen was left mid-sweep. Nothing is known, so
            // nothing is claimed — and the quiet sweep is left un-swept
            // so the next visit tries again rather than reporting a
            // cancellation forever.
            if announcingNothingFound { purchaseRestore = .idle }
            return
        }
        hasSweptPurchases = true

        if announcingNothingFound || restored > 0 || !failures.isEmpty {
            // A sweep nobody asked for stays quiet unless it has news.
            // Announcing "the App Store has no purchase to restore" on a
            // screen someone opened to check their backups would be an
            // answer to a question they did not ask.
            purchaseRestore = .finished(
                restored: restored,
                held: held,
                checked: checked,
                heldUnknown: heldUnknown,
                syncFailed: syncFailed,
                failures: failures)
        } else {
            purchaseRestore = .idle
        }
        // A recovered credential changes what the next upload can do, so
        // an operator sitting on "Payment needed" is told what to do
        // about it. `refresh()` cannot clear that state on its own: it
        // is derived from a snapshot still awaiting payment, and only a
        // run that actually places those bytes resolves it.
        refresh()
        if !restoredFor.isEmpty {
            for vendor in vendors
            where restoredFor.contains(vendor.id) && vendor.flow.isPaymentRequired {
                vendor.flow.noteRestoredPurchase()
            }
            // A credential is what lets a paid operator answer at all,
            // so the list it refused a moment ago is worth asking again.
            await loadSnapshots()
        }
    }

    /// A cancelled request is not a failed one. Leaving the screen
    /// mid-sweep used to leave a raw `URLError` in the row.
    private static func isCancellation(_ message: String) -> Bool {
        message.contains("cancelled") || message.contains("Cancelled")
            || message.contains("CancellationError")
    }

    /// What one operator reported in the last run, if it reported
    /// anything.
    public func lastRun(for componentId: String) -> BackupFanOut.Outcome? {
        lastRun.first { $0.componentId == componentId }
    }
}
