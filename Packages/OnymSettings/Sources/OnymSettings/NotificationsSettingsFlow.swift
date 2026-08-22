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

    private let enable: () async -> Bool
    private let disable: () async -> Void

    /// - Parameters:
    ///   - isEnabled: the persisted opt-in at presentation time.
    ///   - enable: requests authorization, registers with APNs and the
    ///     push backend. Returns false when authorization was denied.
    ///   - disable: unregisters everywhere and clears the opt-in.
    public init(
        isEnabled: Bool,
        enable: @escaping () async -> Bool,
        disable: @escaping () async -> Void
    ) {
        self.isEnabled = isEnabled
        self.enable = enable
        self.disable = disable
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
        }
    }
}
