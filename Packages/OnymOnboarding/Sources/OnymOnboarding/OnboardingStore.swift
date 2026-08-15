import Foundation

/// Persistence seam for the one bit the onboarding gate needs: has the
/// user completed (or been grandfathered past) the first-launch flow.
public protocol OnboardingStore: Sendable {
    /// Whether the completion flag is set.
    func hasCompletedOnboarding() -> Bool
    /// Set the completion flag. Idempotent.
    func markOnboardingCompleted()
    /// Clear the completion flag, so the next launch onboards again.
    /// The app's `--reset-keychain` test path calls this instead of
    /// hardcoding the storage key. Idempotent.
    func resetOnboarding()
}

/// Production `OnboardingStore`. Single boolean under
/// `app.onym.ios.onboarding.completed` — cleared by the app's
/// `--reset-keychain` test path alongside the other first-run state.
///
/// `@unchecked Sendable` for the same reason as the sibling
/// UserDefaults stores (e.g. `UserDefaultsSeatSelectionStore`):
/// `UserDefaults` is documented thread-safe but not formally
/// `Sendable`.
public struct UserDefaultsOnboardingStore: OnboardingStore, @unchecked Sendable {
    /// Internal so tests can assert the exact key the app's reset path
    /// must clear.
    static let key = "app.onym.ios.onboarding.completed"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func hasCompletedOnboarding() -> Bool {
        defaults.bool(forKey: Self.key)
    }

    public func markOnboardingCompleted() {
        defaults.set(true, forKey: Self.key)
    }

    public func resetOnboarding() {
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
    public static func shouldOnboard(
        store: any OnboardingStore,
        isExistingUser: () -> Bool
    ) -> Bool {
        if store.hasCompletedOnboarding() { return false }
        if isExistingUser() { return false }
        return true
    }
}
