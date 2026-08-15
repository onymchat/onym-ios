import Foundation

/// Persistence seam for the two bits the onboarding gate needs: has
/// the user completed (or been grandfathered past) the first-launch
/// flow, and did they explicitly ask to run it again.
public protocol OnboardingStore: Sendable {
    /// Whether the completion flag is set.
    func hasCompletedOnboarding() -> Bool
    /// Set the completion flag. Idempotent. Also ends any pending
    /// restart request — completion is completion, however the walk
    /// was entered.
    func markOnboardingCompleted()
    /// Clear the completion flag AND any restart request, so the next
    /// launch onboards again as if fresh. The app's `--reset-keychain`
    /// test path calls this instead of hardcoding the storage keys.
    /// Idempotent.
    func resetOnboarding()
    /// Whether the user explicitly asked to re-run onboarding
    /// (Settings → Restart Onboarding) and hasn't completed it since.
    /// Persisted: an app killed mid-restart-walk resumes on next
    /// launch. This is the signal that OUTRANKS grandfathering in
    /// `OnboardingGate.shouldOnboard` — an existing user's configured
    /// state must suppress onboarding they never asked for, never
    /// onboarding they explicitly requested.
    func isRestartRequested() -> Bool
    /// Record an explicit restart request: sets the restart marker and
    /// clears the completion flag in one intent, so every reading of
    /// the store agrees the walk is due. Idempotent.
    func requestRestart()
}

/// Production `OnboardingStore`. Two booleans —
/// `app.onym.ios.onboarding.completed` and
/// `app.onym.ios.onboarding.restartRequested` — cleared together by
/// the app's `--reset-keychain` test path alongside the other
/// first-run state.
///
/// `@unchecked Sendable` for the same reason as the sibling
/// UserDefaults stores (e.g. `UserDefaultsSeatSelectionStore`):
/// `UserDefaults` is documented thread-safe but not formally
/// `Sendable`.
public struct UserDefaultsOnboardingStore: OnboardingStore, @unchecked Sendable {
    /// Internal so tests can assert the exact keys the app's reset
    /// path must clear.
    static let key = "app.onym.ios.onboarding.completed"
    static let restartKey = "app.onym.ios.onboarding.restartRequested"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasCompletedOnboarding() -> Bool {
        defaults.bool(forKey: Self.key)
    }

    public func markOnboardingCompleted() {
        defaults.set(true, forKey: Self.key)
        defaults.removeObject(forKey: Self.restartKey)
    }

    public func resetOnboarding() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.restartKey)
    }

    public func isRestartRequested() -> Bool {
        defaults.bool(forKey: Self.restartKey)
    }

    public func requestRestart() {
        defaults.set(true, forKey: Self.restartKey)
        defaults.removeObject(forKey: Self.key)
    }
}

/// The launch-time gate decision, including grandfathering: users who
/// predate onboarding have no completion flag but plenty of configured
/// state, and must not be onboarded as if the app were fresh.
public enum OnboardingGate {
    /// Whether first-launch onboarding should be presented.
    ///
    /// - `store` holds the completion flag written by
    ///   `OnboardingFlow.complete()`.
    /// - `isExistingUser` is the injected existing-user signal — the
    ///   app passes "any `hasUserInteracted` or a moderation mandate is
    ///   present". It is only consulted when the flag is absent, so the
    ///   (potentially costier) probe never runs on the steady-state
    ///   path.
    ///
    /// Either signal — completed flag OR existing-user state — means NO
    /// onboarding. The probe is a pure read: it never writes the flag
    /// itself (completion is `OnboardingFlow.complete()`'s job), so a
    /// grandfathered user simply answers false here on every launch.
    ///
    /// The one thing that OUTRANKS both: an explicit restart request
    /// (Settings → Restart Onboarding). Grandfathering exists to stop
    /// configured users being onboarded as if fresh — it must never
    /// stop onboarding they explicitly asked for, including the resume
    /// after an app killed mid-restart-walk. Cold-boot behavior for
    /// upgraders is unchanged: they never carry the marker.
    public static func shouldOnboard(
        store: any OnboardingStore,
        isExistingUser: () -> Bool
    ) -> Bool {
        if store.isRestartRequested() { return true }
        if store.hasCompletedOnboarding() { return false }
        if isExistingUser() { return false }
        return true
    }
}
