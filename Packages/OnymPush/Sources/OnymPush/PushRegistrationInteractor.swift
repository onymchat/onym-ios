import CryptoKit
import Foundation

/// Reconciles what this device wants the push backend to know with
/// what the backend was last told. The inputs — the APNs token, the
/// identity-derived subscription set, the relay list, the opt-in —
/// all change independently; every change lands here, is debounced,
/// and becomes at most one replace-all `register` call (or an
/// `unregister` when push is turned off).
///
/// The transport repositories own their lifecycles; this interactor
/// only *observes* identity and relay state and talks to the push
/// backend. It never drives transports.
public actor PushRegistrationInteractor {
    private let client: PushBackendClient
    private let signer: PushSigner
    private let attestation: PushDeviceAttestationProvider
    private let preferences: PushPreferenceStore
    private let debounce: Duration
    /// Re-register even when nothing changed, so the backend's
    /// stale-registration sweep (60 days) never reaps a live device.
    private let refreshInterval: TimeInterval
    /// Also re-register when the backend's own `expiresAt` is this
    /// close, whichever comes first.
    private let expiryMargin: TimeInterval = 7 * 24 * 3600
    private let clock: @Sendable () -> Date

    private var apnsToken: Data?
    private var subscriptions: [PushSubscription]?
    private var pendingReconcile: Task<Void, Never>?
    /// Reconciliation must never overlap itself: two interleaved
    /// passes would spend two single-use session signatures on the
    /// same state. One pass runs; passes requested meanwhile coalesce
    /// into exactly one follow-up.
    private var reconcileInFlight = false
    private var reconcileQueuedWhileInFlight = false

    public init(
        client: PushBackendClient,
        signer: PushSigner,
        attestation: PushDeviceAttestationProvider,
        preferences: PushPreferenceStore = PushPreferenceStore(),
        debounce: Duration = .seconds(2),
        refreshInterval: TimeInterval = 7 * 24 * 3600,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.signer = signer
        self.attestation = attestation
        self.preferences = preferences
        self.debounce = debounce
        self.refreshInterval = refreshInterval
        self.clock = clock
    }

    // MARK: - Inputs

    /// APNs delivered (or rotated) the device token.
    public func updateToken(_ token: Data) {
        apnsToken = token
        scheduleReconcile()
    }

    /// The desired subscription set changed: an identity was added or
    /// removed, or the relay list changed. An empty array is
    /// meaningful — it clears every tag at the backend while keeping
    /// the device registered.
    public func updateSubscriptions(_ desired: [PushSubscription]) {
        subscriptions = desired
        scheduleReconcile()
    }

    /// The user turned push on (authorization already granted and
    /// `registerForRemoteNotifications` called by the UI layer).
    public func pushEnabled() {
        scheduleReconcile()
    }

    /// The user turned push off. The intent to unregister is persisted
    /// *before* the attempt and cleared only on success, so an offline
    /// opt-out is retried at every reconcile opportunity rather than
    /// leaving the device registered on the server. Falls back to the
    /// last successfully registered token when APNs has not delivered
    /// one this launch.
    public func pushDisabled() async {
        pendingReconcile?.cancel()
        pendingReconcile = nil
        let token = apnsToken ?? preferences.lastRegisteredToken
        preferences.clearRegistration()
        guard let token else { return }
        preferences.setPendingUnregister(token: token)
        await drainPendingUnregister()
    }

    /// An opportunity moment (app foregrounded): re-run reconciliation
    /// so the periodic refresh happens without a dedicated timer.
    public func appForegrounded() {
        scheduleReconcile()
    }

    // MARK: - Reconciliation

    private func scheduleReconcile() {
        pendingReconcile?.cancel()
        let delay = debounce
        pendingReconcile = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    private func reconcile() async {
        if reconcileInFlight {
            reconcileQueuedWhileInFlight = true
            return
        }
        reconcileInFlight = true
        defer { reconcileInFlight = false }
        repeat {
            reconcileQueuedWhileInFlight = false
            await reconcilePass()
        } while reconcileQueuedWhileInFlight
    }

    private func reconcilePass() async {
        // A pending unregister is the user's last unhonored
        // instruction — it drains first, whatever the current opt-in.
        await drainPendingUnregister()

        guard preferences.isEnabled,
              let token = apnsToken,
              let subscriptions else { return }

        let fingerprint = Self.fingerprint(token: token, subscriptions: subscriptions)
        let now = clock()
        if fingerprint == preferences.lastRegistrationFingerprint,
           let registeredAt = preferences.lastRegisteredAt,
           now.timeIntervalSince(registeredAt) < refreshInterval,
           let expiresAt = preferences.registrationExpiresAt,
           now < expiresAt.addingTimeInterval(-expiryMargin) {
            return
        }

        do {
            let serverKey = try await client.registrationKey()
            let envelope = try PushTokenEnvelope.seal(apnsToken: token, serverPublicKey: serverKey)
            let userKey = try await signer.userKeyID()
            let deviceToken = await attestation.currentToken()
            let timestamp = clock()
            let payload = SignedPushSessionPayload.register(
                deviceToken: deviceToken,
                userKey: userKey,
                timestamp: timestamp,
                apnsToken: token,
                subscriptions: subscriptions
            )
            let signature = try await signer.sign(payload)
            let response = try await client.register(
                PushRegisterRequest(
                    deviceToken: deviceToken,
                    userKey: userKey,
                    timestamp: timestamp,
                    signature: signature,
                    tokenEnvelope: envelope,
                    subscriptions: subscriptions
                )
            )
            preferences.recordRegistration(
                fingerprint: fingerprint,
                token: token,
                at: timestamp,
                expiresAt: response.expiresAt
            )
            // A registration for this token supersedes any unregister
            // still pending for it (replace-all upsert): draining it
            // later would tear down the live registration.
            if preferences.pendingUnregisterToken == token {
                preferences.clearPendingUnregister()
            }
        } catch {
            // Deliberately quiet: registration is retried on the next
            // input change or foreground, and per the no-activity-log
            // stance nothing user-linked is recorded about the failure.
        }
    }

    private func drainPendingUnregister() async {
        guard let pending = preferences.pendingUnregisterToken else { return }
        do {
            try await unregister(token: pending)
            preferences.clearPendingUnregister()
            if preferences.lastRegisteredToken == pending {
                preferences.clearLastRegisteredToken()
            }
        } catch {
            // Stays pending; retried at the next reconcile opportunity.
        }
    }

    private func unregister(token: Data) async throws {
        let serverKey = try await client.registrationKey()
        let envelope = try PushTokenEnvelope.seal(apnsToken: token, serverPublicKey: serverKey)
        let userKey = try await signer.userKeyID()
        let deviceToken = await attestation.currentToken()
        let timestamp = clock()
        let payload = SignedPushSessionPayload.unregister(
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            apnsToken: token
        )
        let signature = try await signer.sign(payload)
        try await client.unregister(
            PushUnregisterRequest(
                deviceToken: deviceToken,
                userKey: userKey,
                timestamp: timestamp,
                signature: signature,
                tokenEnvelope: envelope
            )
        )
    }

    /// What "already registered" means: same token, same subscription
    /// set, in the digest form the signature itself uses.
    static func fingerprint(token: Data, subscriptions: [PushSubscription]) -> String {
        var input = Data(SHA256.hash(data: token))
        input.append(SignedPushSessionPayload.digest(of: subscriptions))
        return Data(SHA256.hash(data: input)).map { String(format: "%02x", $0) }.joined()
    }
}
