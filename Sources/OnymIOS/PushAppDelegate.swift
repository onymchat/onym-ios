import UIKit

/// The one thing an app delegate is still required for: APNs delivers
/// the device token through `UIApplicationDelegate` callbacks, not a
/// modern async API. This delegate does nothing else — the token is
/// relayed into a stream `PushCoordinator` consumes, and failures are
/// silent (registration is retried on the next foreground; per the
/// no-activity-logging stance nothing is recorded).
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    private static let pipe = AsyncStream.makeStream(of: Data.self)

    /// Every token APNs hands this process, in order. The token can
    /// rotate on restore or reinstall, so this is a stream, not a
    /// one-shot.
    static var deviceTokens: AsyncStream<Data> { pipe.stream }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.pipe.continuation.yield(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Quiet by design; the reconciler retries on later inputs.
    }
}
