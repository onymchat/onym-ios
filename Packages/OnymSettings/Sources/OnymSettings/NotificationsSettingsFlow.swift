import Foundation
import Observation

/// State for the Notifications screen. Deliberately closure-injected —
/// OnymSettings knows nothing about the push stack; the app hands in
/// "what enabling and disabling actually do" (authorization prompt,
/// APNs registration, backend calls) and this flow only sequences and
/// renders them. Views observe state; they never drive registration
/// themselves.
@MainActor
@Observable
public final class NotificationsSettingsFlow {
    public private(set) var isEnabled: Bool
    public private(set) var isWorking = false
    /// The user flipped the toggle on but the system authorization was
    /// denied — the switch snaps back and the UI points at system
    /// Settings.
    public private(set) var authorizationDenied = false
    /// On, but the backend has not yet accepted a registration —
    /// authorization is granted while the APNs token and register call
    /// are still in flight. The view shows "activating" instead of
    /// claiming the wake path works before it does.
    public private(set) var registrationPending = false

    private let enable: () async -> Bool
    private let disable: () async -> Void
    private let isRegistrationPending: () -> Bool
    private let readIsEnabled: (() -> Bool)?
    private let reconcileWithSystem: (() async -> Void)?

    /// - Parameters:
    ///   - isEnabled: the persisted opt-in at presentation time.
    ///   - enable: requests authorization, registers with APNs and the
    ///     push backend. Returns false when authorization was denied.
    ///   - disable: unregisters everywhere and clears the opt-in.
    ///   - isRegistrationPending: whether the opt-in is on with no
    ///     accepted registration yet — re-read on view appearance and
    ///     after each toggle, since registration completes off-screen.
    ///   - readIsEnabled: the persisted opt-in *now*. The coordinator
    ///     can disable underneath a still-mounted screen (authorization
    ///     revoked in system Settings, app foregrounded back onto this
    ///     view), so the toggle re-reads rather than trusting its
    ///     presentation-time snapshot.
    ///   - reconcileWithSystem: the push stack's foreground
    ///     reconciliation — the step that notices a revoked
    ///     authorization and disables. Awaited before the re-read on
    ///     foreground so this screen reads settled state instead of
    ///     racing the root-level hook that runs the same check.
    public init(
        isEnabled: Bool,
        enable: @escaping () async -> Bool,
        disable: @escaping () async -> Void,
        isRegistrationPending: @escaping () -> Bool = { false },
        readIsEnabled: (() -> Bool)? = nil,
        reconcileWithSystem: (() async -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.enable = enable
        self.disable = disable
        self.isRegistrationPending = isRegistrationPending
        self.readIsEnabled = readIsEnabled
        self.reconcileWithSystem = reconcileWithSystem
        registrationPending = isRegistrationPending()
    }

    public func setEnabled(_ wanted: Bool) async {
        guard wanted != isEnabled, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        if wanted {
            authorizationDenied = false
            let granted = await enable()
            isEnabled = granted
            authorizationDenied = !granted
        } else {
            await disable()
            isEnabled = false
            // The denial note described a previous attempt; an
            // explicit off makes it stale.
            authorizationDenied = false
        }
        refreshRegistrationState()
    }

    /// Registration completes off-screen (APNs token delivery, then
    /// the backend call) and the coordinator can disable off-screen
    /// too, so the view re-reads both on appearance.
    public func refreshRegistrationState() {
        if let readIsEnabled {
            isEnabled = readIsEnabled()
        }
        registrationPending = isRegistrationPending()
    }

    /// Foreground is when a revoke made in system Settings becomes
    /// knowable, and `.onAppear` does not fire for a screen that stayed
    /// mounted across the trip out and back — which is exactly the trip
    /// the denial note above sends the user on. Reconciling here rather
    /// than only re-reading is deliberate: the root-level foreground
    /// hook runs the same check on its own detached task, so a bare
    /// re-read could win the race and show the pre-revoke answer with
    /// nothing left to correct it.
    public func appForegrounded() async {
        await reconcileWithSystem?()
        refreshRegistrationState()
    }
}
