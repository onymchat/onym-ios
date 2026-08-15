import Foundation
import Observation
import OnymChain
import OnymModeration
import OnymOnboarding
import OnymTransportBlossom
import OnymTransportNostr

/// Settings → Restart Onboarding. Bridges the Settings action to the
/// RootView cover WITHOUT re-running the cold-boot gate: the launch
/// gate's grandfathering probe exists to stop configured users being
/// onboarded as if fresh, and would (correctly) answer "existing
/// user" here — so an explicit restart goes through its own
/// observable signal plus a persisted marker, never through a
/// weakened probe.
///
/// Restart KEEPS everything: identity, chats, messages, and every
/// current seat selection. Only the walk re-runs — the step surfaces
/// render the applied configuration (ACTIVE badges, configured rows)
/// and change nothing until the user does.
///
/// - `requestRestart()` writes the persisted restart marker (which
///   also clears the completion flag — `OnboardingStore` contract)
///   and raises `pendingRestart` for RootView to present the cover
///   this session. The marker makes a mid-walk kill resume on next
///   launch through the normal gate (`OnboardingGate.shouldOnboard`
///   checks it before grandfathering).
/// - `consumeRestart()` lowers only the in-session signal; the
///   persisted marker is cleared by `markOnboardingCompleted()` when
///   the walk finishes, exactly like a first run.
@MainActor
@Observable
final class OnboardingRestartController {
    private(set) var pendingRestart = false

    private let store: any OnboardingStore

    init(store: any OnboardingStore) {
        self.store = store
    }

    func requestRestart() {
        store.requestRestart()
        pendingRestart = true
    }

    func consumeRestart() {
        pendingRestart = false
    }
}

/// The launch-time existing-user probe behind
/// `OnboardingGate.shouldOnboard`: users who predate onboarding have
/// no completion flag but plenty of configured state, and must never
/// be onboarded as if the install were fresh.
///
/// The probe is a PURE READ of the synchronous stores (the gate
/// decision happens in `OnymIOSApp.init`, before any repository
/// exists) and it never writes the completion flag — completion is
/// `OnboardingFlow.complete()`'s job alone, so a grandfathered user
/// simply answers true here on every launch.
///
/// Deliberately NOT part of the signal: the seeded defaults. The
/// Nostr / Blossom repositories seed their configuration with
/// `hasUserInteracted == false` on first construction, so a fresh
/// install still reads as fresh after the seed lands.
enum OnboardingLaunch {
    /// Any `hasUserInteracted` across the transport/notary
    /// configurations, or any moderation mandate record — either one
    /// proves a user who already ran (and shaped) this app.
    static func isExistingUser(
        relayerStore: any RelayerSelectionStore = UserDefaultsRelayerSelectionStore(),
        nostrStore: any NostrRelaysSelectionStore = UserDefaultsNostrRelaysSelectionStore(),
        blossomStore: any BlossomServersSelectionStore = UserDefaultsBlossomServersSelectionStore(),
        mandateStore: any MandateStore = UserDefaultsMandateStore()
    ) -> Bool {
        if relayerStore.loadConfiguration().hasUserInteracted { return true }
        if nostrStore.load().hasUserInteracted { return true }
        if blossomStore.load().hasUserInteracted { return true }
        if !mandateStore.load().isEmpty { return true }
        return false
    }
}
