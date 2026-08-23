import Foundation
import OnymFoundation
import OnymIdentity
import OnymModeration
import OnymPush
import OnymTransportNostr
import UIKit
import UserNotifications

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
    /// Whether the system's notification authorization has been
    /// revoked. Injected so the privacy-load-bearing "revoked while
    /// enabled ⇒ full disable" gate is unit-testable; production reads
    /// `UNUserNotificationCenter`.
    private let notificationAuthorizationDenied: @Sendable () async -> Bool

    /// nil until the first identity read completes — an actually-empty
    /// identity list (loaded, count 0) becomes `[]`, which is
    /// meaningful and clears the backend's tag set. The distinction
    /// keeps a slow keychain read from causing an empty-set register
    /// followed immediately by a re-register.
    private var latestTags: [String]?
    /// Same nil-until-loaded shape as `latestTags`: nil means the
    /// relay configuration has not been read yet, `[]` is meaningful —
    /// the user removed every relay, so nothing is watchable and the
    /// backend's subscription set must be cleared (see
    /// `pushDesiredSubscriptions`).
    private var latestRelays: [String]?

    init(
        identityRepository: IdentityRepository,
        relaysRepository: NostrRelaysRepository,
        client: PushBackendClient = URLSessionPushBackendClient(),
        // The device-local push key, never an identity's key: push
        // registrations refresh on their own schedule, and an
        // identity-keyed signature would let the backend link the
        // persona keys that sign successive refreshes for one device
        // token. See `DevicePushSigner`.
        signer: PushSigner = DevicePushSigner(),
        preferences: PushPreferenceStore = PushPreferenceStore(),
        notificationAuthorizationDenied: @escaping @Sendable () async -> Bool = {
            await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus == .denied
        }
    ) {
        self.identityRepository = identityRepository
        self.relaysRepository = relaysRepository
        self.preferences = preferences
        self.notificationAuthorizationDenied = notificationAuthorizationDenied
        self.interactor = PushRegistrationInteractor(
            client: client,
            signer: signer,
            attestation: DCDevicePushAttestation(),
            preferences: preferences
        )
    }

    nonisolated var isEnabled: Bool {
        preferences.isEnabled
    }

    /// Enabled but not yet accepted by the backend: authorization was
    /// granted, but no registration fingerprint has been recorded —
    /// Settings shows this as "activating" rather than claiming the
    /// wake path works before it does.
    nonisolated var registrationPending: Bool {
        preferences.isEnabled && preferences.lastRegistrationFingerprint == nil
    }

    /// Runs for the scene's life from a `RootView`-level `.task`.
    func run() async {
        if preferences.isEnabled {
            // Cold launch reconciles with system Settings BEFORE
            // touching APNs: SwiftUI never fires `.onChange(of:
            // scenePhase)` for the initial `.active`, so without this
            // check here an authorization revoked while the app was
            // gone would leave the server registration alive until
            // some later foreground.
            if await notificationAuthorizationDenied() {
                await disable()
            } else {
                // A fresh launch with push already enabled re-requests
                // the token — it can have rotated while the app was
                // gone.
                await registerWithAPNs()
            }
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
        // Nothing left in the app should want the token; drop the
        // replayed copy rather than holding a secret longer than
        // needed. APNs re-delivers on the next enable.
        PushAppDelegate.clearLatestToken()
    }

    /// Foreground hook, same shape as the moderation gate's: gives the
    /// interactor its periodic-refresh opportunity without a timer —
    /// and reconciles with system Settings first: if the user revoked
    /// notification authorization there while the in-app preference
    /// says on, the toggle is a lie and the server still holds a
    /// registration, so this runs the full disable path.
    func appForegrounded() async {
        if preferences.isEnabled, await notificationAuthorizationDenied() {
            await disable()
            return
        }
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
    /// row survives, so re-adding an identity needs no re-consent) —
    /// and an empty *relay* list resolves to the same empty
    /// subscription set: with no relay to watch, no tag is watchable,
    /// and the backend refuses entries with zero relays. The two empty
    /// cases are therefore symmetric on the wire; what they share is
    /// "stop watching everything, keep the device registered". Only a
    /// not-yet-loaded input (nil) is withheld, so a slow first read
    /// can't cause a clearing register followed by a re-register.
    private func pushDesiredSubscriptions() async {
        guard let latestTags, let latestRelays else { return }
        let relays = Self.cappedRelays(latestRelays)
        let subscriptions = relays.isEmpty
            ? []
            : latestTags.map { PushSubscription(tag: $0, relays: relays) }
        await interactor.updateSubscriptions(subscriptions)
    }

    // MARK: - Backend relay caps

    /// The deployed backend's per-request caps
    /// (onym-push `apple/README.md`, `apple/src/config.rs` defaults):
    /// at most 4 relays per tag, 8 distinct relay hosts per device,
    /// and 4 URLs per host per device. Every tag shares this one relay
    /// list, so capping the list once satisfies the per-tag cap —
    /// and because 4 URLs can span at most 4 hosts with at most 4 on
    /// any one, it satisfies both host caps too; they are still
    /// enforced here explicitly so a future cap change fails safe.
    private static let maxRelaysPerTag = 4
    private static let maxRelayHosts = 8
    private static let maxRelaysPerHost = 4

    /// The one relay the backend exempts from its capacity caps.
    static let defaultRelayURL = "wss://nostr.onym.app"

    /// Truncates the configured relay list to what the backend will
    /// accept, deterministically: the default relay first (the backend
    /// exempts it from capacity caps, so it is the never-wasted slot),
    /// then the user's configured relays in their configured order,
    /// deduplicated, dropped once any cap is reached. Truncation is
    /// silent by design — recording "which relays we didn't register"
    /// would be an activity log this app declines to keep, and a
    /// refused register would silence pushes entirely, which is worse
    /// than watching the user's four highest-priority relays.
    static func cappedRelays(_ configured: [String]) -> [String] {
        var ordered = configured
        if let index = ordered.firstIndex(of: defaultRelayURL), index != 0 {
            ordered.remove(at: index)
            ordered.insert(defaultRelayURL, at: 0)
        }
        var result: [String] = []
        var urlsPerHost: [String: Int] = [:]
        for relay in ordered {
            guard result.count < maxRelaysPerTag else { break }
            guard !result.contains(relay) else { continue }
            let host = URL(string: relay)?.host?.lowercased() ?? relay
            let count = urlsPerHost[host] ?? 0
            if count == 0, urlsPerHost.count >= maxRelayHosts { continue }
            guard count < maxRelaysPerHost else { continue }
            urlsPerHost[host] = count + 1
            result.append(relay)
        }
        return result
    }

    private func registerWithAPNs() async {
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }
}
