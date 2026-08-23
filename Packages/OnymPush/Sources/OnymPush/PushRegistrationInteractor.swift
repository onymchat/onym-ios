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
    /// close, whichever comes first. Capped at half the window the
    /// backend actually granted: a margin as long as the whole window
    /// would make "far enough from expiry" unsatisfiable and turn
    /// every foreground into a register (and a spent signature).
    private static let maxExpiryMargin: TimeInterval = 7 * 24 * 3600
    private let clock: @Sendable () -> Date

    private var apnsToken: Data?
    private var subscriptions: [PushSubscription]?
    /// The *sleeping* debounce only — never the pass itself. Inputs
    /// (and `pushDisabled`) cancel this handle to coalesce or drop a
    /// pass that has not started; the pass body runs in a separate
    /// unstructured Task that nothing here ever cancels, so an input
    /// arriving mid-pass can never abort in-flight HTTP (wasting a
    /// single-use signature the backend may already have spent) and a
    /// disable can never delegate its drain to a Task it just
    /// cancelled — where every URLSession call would throw
    /// `URLError.cancelled` immediately and be swallowed.
    private var pendingDebounce: Task<Void, Never>?
    /// Reconciliation must never overlap itself — nor the opt-out
    /// drain, which takes the same slot: two interleaved passes would
    /// spend two single-use session signatures on the same state, and
    /// a register still in flight could land *after* an opt-out's
    /// unregister. One pass runs; passes requested meanwhile coalesce
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

    /// Test-only observability for errors reconciliation deliberately
    /// swallows (registration is retried, and per the no-activity-log
    /// stance nothing is recorded about the failure). `nil` in
    /// production.
    private var onReconcileFailure: (@Sendable (Error) -> Void)?

    /// Intended for tests only — but it is public production API, and
    /// nothing here can stop a caller from wiring the hook to a
    /// persistent sink and building exactly the failure/activity log
    /// this package declines to keep. The app target must never set
    /// it; a production caller reaching for it should treat this
    /// caveat as the review gate.
    public func setOnReconcileFailure(_ hook: (@Sendable (Error) -> Void)?) {
        onReconcileFailure = hook
    }

    // MARK: - Inputs

    /// APNs delivered (or rotated) the device token. On rotation the
    /// previous token is queued for unregister (see `reconcilePass`):
    /// the backend keys registrations by token hash, so the old row
    /// would otherwise stay wake-able until the 60-day sweep.
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
        // Cancels only a debounce still sleeping. A pass already
        // running keeps its Task: it holds the single pass slot, so
        // the `claimPass()` below fails and the drain is queued — and
        // the holder drains it from a Task no one cancelled.
        pendingDebounce?.cancel()
        pendingDebounce = nil
        let token = apnsToken ?? preferences.lastRegisteredToken
        preferences.clearRegistration()
        guard let token else { return }
        preferences.addPendingUnregister(token: token)
        // The drain takes the same single pass slot reconciliation
        // uses: running alongside a pass would spend a second
        // single-use signature, and that pass's register could land
        // *after* this unregister and leave the device registered. A
        // pass holding the slot drains this before it releases it.
        guard claimPass() else { return }
        defer { reconcileInFlight = false }
        await drainPendingUnregister()
        await runQueuedPasses()
    }

    /// An opportunity moment (app foregrounded): re-run reconciliation
    /// so the periodic refresh happens without a dedicated timer.
    public func appForegrounded() {
        scheduleReconcile()
    }

    // MARK: - Reconciliation

    private func scheduleReconcile() {
        pendingDebounce?.cancel()
        let delay = debounce
        pendingDebounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // The pass runs in its own unstructured Task so that a
            // later input cancelling the *next* debounce — or a
            // disable cancelling this one a beat too late — never
            // propagates cancellation into a pass whose HTTP is
            // already in flight. Overlap is impossible regardless:
            // `claimPass()` serializes passes on the actor.
            Task { await self?.reconcile() }
        }
    }

    private func reconcile() async {
        guard claimPass() else { return }
        defer { reconcileInFlight = false }
        await reconcilePass()
        await runQueuedPasses()
    }

    /// Claims the single pass slot. When a pass already holds it, this
    /// records that another is wanted — the holder runs it before
    /// releasing — and yields.
    private func claimPass() -> Bool {
        if reconcileInFlight {
            reconcileQueuedWhileInFlight = true
            return false
        }
        reconcileInFlight = true
        return true
    }

    /// Whatever was requested during a pass collapses into exactly one
    /// follow-up, which re-checks the fingerprint. No suspension point
    /// separates the last check here from releasing the slot, so a
    /// request can never be queued and then stranded.
    private func runQueuedPasses() async {
        while reconcileQueuedWhileInFlight {
            reconcileQueuedWhileInFlight = false
            await reconcilePass()
        }
    }

    private func reconcilePass() async {
        // A pending unregister is the user's last unhonored
        // instruction — it drains first, whatever the current opt-in.
        await drainPendingUnregister()

        guard preferences.isEnabled,
              let token = apnsToken,
              let subscriptions else { return }

        // APNs rotated the token: the backend keys registrations by
        // token hash, so the replaced row would stay wake-able until
        // the 60-day sweep. Queue the old token through the existing
        // pending-unregister path (persisted, retried, deduplicated)
        // and try to drain it now, before its replacement registers.
        if let previous = preferences.lastRegisteredToken, previous != token {
            preferences.addPendingUnregister(token: previous)
            await drainPendingUnregister()
        }

        let fingerprint = Self.fingerprint(token: token, subscriptions: subscriptions)
        let now = clock()
        if fingerprint == preferences.lastRegistrationFingerprint,
           let registeredAt = preferences.lastRegisteredAt,
           now.timeIntervalSince(registeredAt) < refreshInterval,
           let expiresAt = preferences.registrationExpiresAt,
           !Self.refreshDueByExpiry(now: now, registeredAt: registeredAt, expiresAt: expiresAt) {
            return
        }

        // Read before the attempt, deliberately: an unregister still
        // unhonored *now* is superseded by the registration about to
        // replace it, but one the user asks for *during* the attempt
        // is the newer instruction and must survive it.
        let unregisterWasPending = preferences.pendingUnregisterTokens.contains(token)

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
            // Re-read the opt-in *after* the awaits: a disable that
            // landed while the register was in flight already cleared
            // the record and must win. Recording here would leave prefs
            // claiming "registered" while disabled — and the register
            // that just reached the backend must be torn down, so the
            // token goes onto the pending-unregister path instead (the
            // follow-up pass the disable queued drains it).
            guard preferences.isEnabled else {
                preferences.addPendingUnregister(token: token)
                return
            }
            preferences.recordRegistration(
                fingerprint: fingerprint,
                token: token,
                at: timestamp,
                expiresAt: response.expiresAt
            )
            // A registration for this token retires an unregister that
            // was already pending for it (replace-all upsert): draining
            // it later would tear down the live registration. Only
            // *this* token's entry is removed — unregisters pending
            // for other tokens (a failed rotation's debt) are untouched
            // — and an opt-out that arrived mid-attempt is left alone:
            // the follow-up pass drains it.
            if unregisterWasPending {
                preferences.removePendingUnregister(token: token)
            }
        } catch {
            // Deliberately quiet: registration is retried on the next
            // input change or foreground, and per the no-activity-log
            // stance nothing user-linked is recorded about the failure.
            onReconcileFailure?(error)
        }
    }

    /// A granted window shorter than this (including `expiresAt` at or
    /// behind `registeredAt`) is degenerate: any margin would make the
    /// "already registered" skip unsatisfiable, so every foreground
    /// would re-register and spend a signature.
    static let minimumExpiryWindow: TimeInterval = 3600

    /// Whether the backend-granted window says it is time to
    /// re-register. Normally: within `maxExpiryMargin` of `expiresAt`,
    /// but never more than half the granted window, so a short window
    /// still leaves a usable "already registered" period. A window
    /// below `minimumExpiryWindow` is ignored entirely and the fixed
    /// `refreshInterval` alone paces re-registration — the simplest
    /// rule that keeps the refresh bounded from both sides: a sane
    /// grant is honored with margin, a degenerate one cannot turn
    /// every foreground into a register.
    static func refreshDueByExpiry(now: Date, registeredAt: Date, expiresAt: Date) -> Bool {
        let window = expiresAt.timeIntervalSince(registeredAt)
        guard window >= Self.minimumExpiryWindow else { return false }
        let margin = min(maxExpiryMargin, window / 2)
        return now >= expiresAt.addingTimeInterval(-margin)
    }

    /// Drains every pending unregister, not a single slot: a rotation
    /// whose drain failed and a subsequent disable each owe the
    /// backend a distinct unregister, and both debts must survive.
    private func drainPendingUnregister() async {
        for pending in preferences.pendingUnregisterTokens {
            do {
                try await unregister(token: pending)
                preferences.removePendingUnregister(token: pending)
                if preferences.lastRegisteredToken == pending {
                    preferences.clearLastRegisteredToken()
                }
            } catch {
                // Stays pending; retried at the next reconcile
                // opportunity. The remaining tokens are still tried —
                // they are independent debts.
                onReconcileFailure?(error)
            }
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
