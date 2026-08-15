import Foundation
import OnymChain
import OnymModeration
import OnymTransportBlossom
import OnymTransportNostr

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
