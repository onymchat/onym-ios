import Foundation
import OnymFoundation
import OnymIdentity
import OnymModeration
import OnymPush
import OnymTransportNostr
import UIKit
import UserNotifications

/// The moderation signer already has exactly the shape the push seam
/// needs (`userKeyID` + detached `sign`), so it serves both. The push
/// backend verifies the key and discards it — which identity signs is
/// immaterial there.
extension IdentityModerationSigner: PushSigner {}

/// Push's attestation seam over the same `DCDevice` provider the
/// moderation stack uses: a fresh token per call, nil where the
/// platform has none (simulator, enterprise build).
struct DCDevicePushAttestation: PushDeviceAttestationProvider {
    private let provider = DCDeviceAttestationProvider()

    func currentToken() async -> Data? {
        try? await provider.generateToken()
    }
}

/// Owns the push stack's app-side lifecycle: feeds the reconciling
/// interactor from the APNs token stream, the identity list, and the
/// relay configuration, and gives Settings its enable/disable
/// behavior. Observation only — transports and repositories are never
/// driven from here.
actor PushCoordinator {
    private let interactor: PushRegistrationInteractor
    private let preferences: PushPreferenceStore
    private let identityRepository: IdentityRepository
    private let relaysRepository: NostrRelaysRepository

    private var latestTags: [String] = []
    private var latestRelays: [String] = []

    init(
        identityRepository: IdentityRepository,
        relaysRepository: NostrRelaysRepository,
        client: PushBackendClient = URLSessionPushBackendClient(),
        preferences: PushPreferenceStore = PushPreferenceStore()
    ) {
        self.identityRepository = identityRepository
        self.relaysRepository = relaysRepository
        self.preferences = preferences
        self.interactor = PushRegistrationInteractor(
            client: client,
            signer: IdentityModerationSigner(repository: identityRepository),
            attestation: DCDevicePushAttestation(),
            preferences: preferences
        )
    }

    nonisolated var isEnabled: Bool {
        preferences.isEnabled
    }

    /// Runs for the scene's life from a `RootView`-level `.task`.
    func run() async {
        if preferences.isEnabled {
            // A fresh launch with push already enabled re-requests the
            // token — it can have rotated while the app was gone.
            await registerWithAPNs()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [interactor] in
                for await token in PushAppDelegate.deviceTokens {
                    await interactor.updateToken(token)
                }
            }
            group.addTask { await self.observeIdentities() }
            group.addTask { await self.observeRelays() }
        }
    }

    /// Settings turned push on. Returns false when the system
    /// authorization was denied (the opt-in is then NOT recorded).
    func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted =
            (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return false }
        preferences.setEnabled(true)
        await registerWithAPNs()
        await interactor.pushEnabled()
        return true
    }

    /// Settings turned push off: the backend forgets this device.
    func disable() async {
        preferences.setEnabled(false)
        await MainActor.run { UIApplication.shared.unregisterForRemoteNotifications() }
        await interactor.pushDisabled()
    }

    /// Foreground hook, same shape as the moderation gate's: gives the
    /// interactor its periodic-refresh opportunity without a timer.
    func appForegrounded() async {
        await interactor.appForegrounded()
    }

    // MARK: - Inputs

    private func observeIdentities() async {
        if let summaries = try? await identityRepository.currentIdentities() {
            await apply(tags: summaries.map { InboxTag.derive(from: $0.inboxPublicKey) })
        }
        for await summaries in identityRepository.identitiesStream {
            await apply(tags: summaries.map { InboxTag.derive(from: $0.inboxPublicKey) })
        }
    }

    private func observeRelays() async {
        await apply(relays: relaysRepository.currentEndpoints().map(\.url.absoluteString))
        for await snapshot in relaysRepository.snapshots {
            await apply(relays: snapshot.endpoints.map(\.url.absoluteString))
        }
    }

    private func apply(tags: [String]) async {
        latestTags = tags
        await pushDesiredSubscriptions()
    }

    private func apply(relays: [String]) async {
        latestRelays = relays
        await pushDesiredSubscriptions()
    }

    /// Every identity's tag, watched on every configured relay. An
    /// empty identity list clears the backend's tag set (the device
    /// row survives, so re-adding an identity needs no re-consent).
    private func pushDesiredSubscriptions() async {
        guard !latestRelays.isEmpty else { return }
        let subscriptions = latestTags.map {
            PushSubscription(tag: $0, relays: latestRelays)
        }
        await interactor.updateSubscriptions(subscriptions)
    }

    private func registerWithAPNs() async {
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }
}
