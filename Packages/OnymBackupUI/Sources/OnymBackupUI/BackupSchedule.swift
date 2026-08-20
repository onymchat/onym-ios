import Foundation
import OnymFoundation

/// When a backup is allowed to run.
///
/// One type, on purpose: this is a policy decision with user-visible
/// consequences — the enrolment copy has to describe it accurately — and
/// it should be cheap to change without hunting through view code.
///
/// **v1 is deliberately not a cron.** Two constraints decide it:
///
/// - Uploads are foreground-only. A multi-hundred-megabyte transfer
///   wants a background `URLSession` with a persistent identifier, which
///   is exactly the long-lived, linkable session state this codebase
///   avoids everywhere else.
/// - Snapshots are whole, never incremental, so every run re-uploads the
///   entire history. That argues for deliberate and occasional rather
///   than frequent and automatic.
///
/// So: an explicit "Back up now" is the primary path, and an
/// opportunistic check runs when the app is already open under
/// conditions that make a large upload reasonable. Nothing starts on its
/// own — `UI-Backup.md` §7.1 requires backup to stay off until a person
/// turns it on, and never to enable itself as a side effect.
public struct BackupSchedule: Sendable, Equatable {
    /// Minimum gap between opportunistic runs.
    public var minimumInterval: TimeInterval
    /// Extra delay drawn per run, up to this bound.
    ///
    /// Not battery politeness. Upload timing that tracks send activity
    /// re-leaks per-group activity to the operator through volume and
    /// cadence — the same signal the padding and the opaque archive
    /// exist to suppress. Jitter decouples the two.
    public var maximumJitter: TimeInterval
    /// Require an unmetered connection.
    public var requiresWiFi: Bool
    /// Require external power.
    public var requiresCharging: Bool
    /// How long without a successful backup before the UI calls it
    /// stale. A backup that has quietly stopped working must be a state
    /// a person can see (§7.15).
    public var stalenessThreshold: TimeInterval

    public static let `default` = BackupSchedule(
        minimumInterval: 24 * 60 * 60,
        maximumJitter: 4 * 60 * 60,
        requiresWiFi: true,
        requiresCharging: true,
        stalenessThreshold: 7 * 24 * 60 * 60
    )

    public init(
        minimumInterval: TimeInterval,
        maximumJitter: TimeInterval,
        requiresWiFi: Bool,
        requiresCharging: Bool,
        stalenessThreshold: TimeInterval
    ) {
        self.minimumInterval = minimumInterval
        self.maximumJitter = maximumJitter
        self.requiresWiFi = requiresWiFi
        self.requiresCharging = requiresCharging
        self.stalenessThreshold = stalenessThreshold
    }

    /// Conditions as the device currently reports them.
    public struct Conditions: Sendable, Equatable {
        public var onWiFi: Bool
        public var charging: Bool
        public var lastSuccessAt: Date?
        public var lastAttemptAt: Date?

        public init(
            onWiFi: Bool,
            charging: Bool,
            lastSuccessAt: Date?,
            lastAttemptAt: Date?
        ) {
            self.onWiFi = onWiFi
            self.charging = charging
            self.lastSuccessAt = lastSuccessAt
            self.lastAttemptAt = lastAttemptAt
        }
    }

    /// Whether an *opportunistic* run may start. A person tapping "Back
    /// up now" bypasses this entirely — an explicit request is not
    /// something to second-guess about battery.
    ///
    /// `jitter` is drawn once per app session by the caller and added to
    /// the interval. Without it the run fires the instant the interval
    /// elapses, which is deterministic and therefore correlated with
    /// whatever the person was doing when the previous one ran — the
    /// activity signal this seat spends padding and an opaque archive
    /// suppressing. A declared-but-unapplied jitter would have been
    /// decoration on top of that.
    public func permitsOpportunisticRun(
        _ conditions: Conditions,
        jitter: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        if requiresWiFi && !conditions.onWiFi { return false }
        if requiresCharging && !conditions.charging { return false }
        guard let last = conditions.lastAttemptAt else { return true }
        let wait = minimumInterval + min(max(jitter, 0), maximumJitter)
        return now.timeIntervalSince(last) >= wait
    }

    /// Draw a jitter offset from the CSPRNG.
    ///
    /// Drawn once and held for the session rather than re-drawn per
    /// check: re-drawing would let a caller that polls frequently
    /// sample until it got a small value, which is the same as having no
    /// jitter at all.
    public func drawJitter() -> TimeInterval {
        guard maximumJitter > 0, let bytes = try? SecureRandom.data(8) else { return 0 }
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return maximumJitter * (Double(value % 10_000) / 10_000)
    }

    public func isStale(lastSuccessAt: Date?, now: Date = Date()) -> Bool {
        guard let lastSuccessAt else { return true }
        return now.timeIntervalSince(lastSuccessAt) >= stalenessThreshold
    }
}
