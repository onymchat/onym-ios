import UIKit
import UserNotifications

/// The one thing an app delegate is still required for: APNs delivers
/// the device token through `UIApplicationDelegate` callbacks, not a
/// modern async API. This delegate does nothing else — the token is
/// relayed into streams `PushCoordinator` consumes, and failures are
/// silent (registration is retried on the next foreground; per the
/// no-activity-logging stance nothing is recorded).
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Multicast with replay: every subscriber gets its own stream, a
    /// new subscriber immediately receives the latest token when APNs
    /// already delivered one, and a consumer that goes away is removed
    /// on termination (the house pattern — see
    /// `NostrRelaysRepository.snapshots`) so a cancelled subscriber
    /// does not leak its continuation for the process's life.
    private nonisolated static let lock = NSLock()
    // nonisolated(unsafe): every touch is under `lock`.
    private nonisolated(unsafe) static var latestToken: Data?
    private nonisolated(unsafe) static var continuations:
        [UUID: AsyncStream<Data>.Continuation] = [:]

    /// Every token APNs hands this process, in order, starting with
    /// the most recent one if it already arrived. The token can rotate
    /// on restore or reinstall, so this is a stream, not a one-shot.
    nonisolated static var deviceTokens: AsyncStream<Data> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let replay = latestToken
            lock.unlock()
            continuation.onTermination = { _ in
                lock.lock()
                defer { lock.unlock() }
                continuations.removeValue(forKey: id)
            }
            if let replay {
                continuation.yield(replay)
            }
        }
    }

    /// Disabling push drops the replayed token: nothing left in the
    /// app should want it, and a stale secret should not outlive its
    /// use. APNs re-delivers on the next `registerForRemoteNotifications`.
    nonisolated static func clearLatestToken() {
        lock.lock()
        defer { lock.unlock() }
        latestToken = nil
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Foreground presentation goes through this delegate; set
        // before anything can arrive.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.lock.lock()
        Self.latestToken = deviceToken
        let subscribers = Array(Self.continuations.values)
        Self.lock.unlock()
        for continuation in subscribers {
            continuation.yield(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Quiet by design; the reconciler retries on later inputs.
    }

    /// A push arriving while the app is foregrounded still shows its
    /// (content-free) banner — without this, foreground arrivals are
    /// silently swallowed and the toggle looks broken exactly when the
    /// user is watching.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
