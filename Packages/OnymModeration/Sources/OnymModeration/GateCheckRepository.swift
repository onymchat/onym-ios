import Foundation
import OSLog

/// The declared cadence from the DeviceCheck profile §5: gate check at
/// launch and at least once per `interval`; a device that can't reach
/// the backend operates on its last known state for `offlineGrace`,
/// then degrades to gate-check-required.
public struct GateCheckPolicy: Sendable, Equatable {
    /// Default `P1D`.
    public let interval: TimeInterval
    /// Default `P3D`.
    public let offlineGrace: TimeInterval

    public static let `default` = GateCheckPolicy(
        interval: 86_400,
        offlineGrace: 3 * 86_400
    )

    public init(interval: TimeInterval, offlineGrace: TimeInterval) {
        self.interval = interval
        self.offlineGrace = offlineGrace
    }
}

/// Last successful gate answer + when it landed. Persisted so a
/// relaunch inside the grace window serves the last known state
/// instead of blocking on the network.
public struct PersistedGateState: Codable, Sendable, Equatable {
    public let lastResult: GateCheckResult
    public let lastSuccessAt: Date

    public init(lastResult: GateCheckResult, lastSuccessAt: Date) {
        self.lastResult = lastResult
        self.lastSuccessAt = lastSuccessAt
    }
}

public protocol GateStateStore: Sendable {
    func load() -> PersistedGateState?
    func save(_ state: PersistedGateState?)
}

/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe
/// but not formally `Sendable`.
public struct UserDefaultsGateStateStore: GateStateStore, @unchecked Sendable {
    private static let stateKey = "app.onym.ios.moderation.gateState"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PersistedGateState? {
        guard let data = defaults.data(forKey: Self.stateKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedGateState.self, from: data)
    }

    public func save(_ state: PersistedGateState?) {
        guard let state else {
            defaults.removeObject(forKey: Self.stateKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }
}

/// What the root of the app switches on. Every state except
/// `.operational` with no open cases changes the UI; only `.banned`
/// and `.gateCheckRequired` block it.
public enum GateStatus: Sendable, Equatable {
    /// No active mandate yet — the consent gate applies, not this
    /// one. The protocol remains usable without a mandate; it's this
    /// interface that requires one.
    ///
    /// NOT an operational state and never an escape hatch: losing the
    /// mandate routes to re-consent, after which a fresh gate check
    /// re-reads the device bits. PR-3 owns the RootView gate composition
    /// and must carry the invariant (with a test) that `.notMandated`
    /// cannot reach the operational app, plus a `checkNow()` immediately
    /// after consent.
    case notMandated
    /// Operating. Non-empty `openCases` renders the (non-blocking)
    /// case banner — the case-open mark must not degrade service.
    case operational(openCases: [CaseNotice])
    /// bit1: the app refuses to operate and shows the full ban UX.
    case banned(BanState)
    /// Blocking: no trustworthy gate answer (and grace exhausted).
    case gateCheckRequired(CheckRequiredReason)
}

/// Owns the gate-check cadence: launch + interval checks, offline
/// grace on the persisted last-known state, degradation toward
/// blocking — never toward unmoderated operation. All state
/// transitions go through the pure `derive` so the arithmetic is
/// testable without actor plumbing.
public actor GateCheckRepository {
    /// Outcome of one contact attempt with the backend.
    public enum AttemptOutcome: Sendable, Equatable {
        case success(GateCheckResult)
        /// Network failure / backend unreachable — grace arithmetic
        /// keeps serving the last known state within the window.
        case unreachable
        /// The backend answered and deterministically refused the
        /// session (4xx: replayed/invalid signature, no mandate).
        /// NOT unreachable: cached `.clear` must not keep serving for
        /// the grace window on the say-so of a refusal.
        case refused
    }

    private static let logger = Logger(
        subsystem: "app.onym.ios", category: "moderation"
    )

    private let attestation: any DeviceAttestationProvider
    private let backend: any EnforcementBackendClient
    private let moderation: ModerationRepository
    private let signer: any ModerationSigner
    private let store: any GateStateStore
    private let policy: GateCheckPolicy
    private let clock: @Sendable () -> Date

    private var cached: GateStatus = .notMandated
    private var continuations: [UUID: AsyncStream<GateStatus>.Continuation] = [:]
    private var loopTask: Task<Void, Never>?
    /// Monotonic tag for in-flight checks; stale completions are dropped.
    private var generation: UInt64 = 0

    public init(
        attestation: any DeviceAttestationProvider,
        backend: any EnforcementBackendClient,
        moderation: ModerationRepository,
        signer: any ModerationSigner,
        store: any GateStateStore,
        policy: GateCheckPolicy = .default,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.attestation = attestation
        self.backend = backend
        self.moderation = moderation
        self.signer = signer
        self.store = store
        self.policy = policy
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Launch check + interval loop. Idempotent.
    ///
    /// Each sleep runs to a wall-clock deadline anchored on the previous
    /// check rather than "interval after this check finished", so check
    /// duration doesn't accumulate drift; a deadline already past (the
    /// app was suspended across it) checks immediately and re-anchors.
    /// This loop is the *cadence* floor only — PR-3 must additionally
    /// call `checkNow()` on foreground, and should test a multi-day warm
    /// resume.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self, policy, clock] in
            var due = clock()
            while !Task.isCancelled {
                await self?.checkNow()
                due = due.addingTimeInterval(policy.interval)
                let delay = due.timeIntervalSince(clock())
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    due = clock()
                }
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Gate check

    /// Run one gate check now (launch, foreground, retry button).
    ///
    /// Actor isolation does not span the awaits below, so the cadence
    /// loop and a foreground/retry call can be in flight together. Each
    /// call takes a generation, and a completion whose generation is no
    /// longer the newest is discarded — otherwise a slow `.clear` could
    /// land after a fast `.banned` and reopen the app.
    public func checkNow() async {
        generation &+= 1
        let generation = generation

        guard let record = await moderation.activeMandateRecord() else {
            guard generation == self.generation else { return }
            cached = .notMandated
            publish()
            return
        }

        let attempt = await performAttempt(for: record)
        guard generation == self.generation else { return }

        let (status, persisted) = Self.derive(
            persisted: store.load(),
            attempt: attempt,
            now: clock(),
            policy: policy
        )
        store.save(persisted)
        cached = status
        publish()
    }

    private func performAttempt(for record: MandateRecord) async -> AttemptOutcome {
        // The client never fabricates a token: unavailable attestation
        // sends nil and lets the backend (or grace arithmetic) decide.
        let token: Data?
        if attestation.isSupported {
            token = try? await attestation.generateToken()
        } else {
            token = nil
        }

        do {
            let timestamp = clock()
            let mandateRef = try? record.mandate.mandateHash()
            let signature = try await signer.sign(
                GateCheckRequest.signedPayload(
                    deviceToken: token,
                    userKey: record.mandate.user,
                    mandateRef: mandateRef,
                    timestamp: timestamp
                )
            )
            let request = GateCheckRequest(
                deviceToken: token,
                userKey: record.mandate.user,
                mandateRef: mandateRef,
                timestamp: timestamp,
                signature: signature
            )
            return .success(await sanitize(try await backend.gateCheck(request)))
        } catch {
            // Same deterministic/ambiguous split as everywhere else in
            // the seat: a 4xx (minus the transient 408/429) can't
            // become a success by retrying and must not be mistaken
            // for being offline.
            if case let AuthorityClientError.rejected(rejection) = error,
               (400..<500).contains(rejection.statusCode),
               rejection.statusCode != 408, rejection.statusCode != 429 {
                return .refused
            }
            return .unreachable
        }
    }

    /// A served ban's embedded verdict is display metadata — the marks
    /// are the enforcement. Validate it against the consented manifest
    /// (shape, authority, mandate binding, derived dates, and — with
    /// `ModerationTrust.enforceVerdictSignatures` — the operator
    /// signature) before it reaches the ban screen; an unverifiable
    /// verdict is stripped so its narrative never renders, while the
    /// ban itself stands.
    private func sanitize(_ result: GateCheckResult) async -> GateCheckResult {
        guard case .banned(let state) = result, let verdict = state.verdict else {
            return result
        }
        guard let record = await moderation.mandateRecord(forRef: verdict.mandateRef),
              let consented = record.consentedManifest() else {
            Self.logger.error("banned verdict names an unretained mandate; stripping display verdict")
            return .banned(Self.stripped(state))
        }
        do {
            _ = try VerdictValidator().validate(
                verdict,
                mandate: record.mandate,
                consented: consented,
                now: clock()
            )
            return result
        } catch {
            Self.logger.error("banned verdict failed validation; stripping display verdict: \(error)")
            return .banned(Self.stripped(state))
        }
    }

    private static func stripped(_ state: BanState) -> BanState {
        BanState(
            verdictRef: state.verdictRef,
            verdict: nil,
            authorityContact: state.authorityContact,
            banExpires: state.banExpires,
            appealURL: state.appealURL,
            newHolderURL: state.newHolderURL
        )
    }

    // MARK: - Cadence arithmetic (pure)

    /// The profile-§5 rules as one pure function:
    /// - success → status from the result; persist `{result, now}`;
    /// - unreachable within `offlineGrace` of the last success → keep
    ///   serving the last known state;
    /// - unreachable past grace → `.gateCheckRequired(.offlineGraceExpired)`,
    ///   persisted state kept (a later success overwrites it);
    /// - unreachable with no history → `.gateCheckRequired(.neverChecked)`;
    /// - unreachable with the clock behind `lastSuccessAt` →
    ///   `.gateCheckRequired(.clockRollback)`. A negative age would
    ///   otherwise satisfy the grace comparison forever, so winding the
    ///   clock back and blocking only the backend would pin a cached
    ///   `.clear` indefinitely.
    /// Degradation only ever moves toward blocking.
    public static func derive(
        persisted: PersistedGateState?,
        attempt: AttemptOutcome,
        now: Date,
        policy: GateCheckPolicy
    ) -> (GateStatus, PersistedGateState?) {
        switch attempt {
        case .success(let result):
            return (status(for: result), PersistedGateState(lastResult: result, lastSuccessAt: now))
        case .refused:
            // Persisted state is kept — a later successful check
            // overwrites it — but a refusal blocks now: it is a
            // reachable backend's answer, not a network condition the
            // grace window exists for.
            return (.gateCheckRequired(.backendRefused), persisted)
        case .unreachable:
            guard let persisted else {
                return (.gateCheckRequired(.neverChecked), nil)
            }
            let age = now.timeIntervalSince(persisted.lastSuccessAt)
            if age < 0 {
                return (.gateCheckRequired(.clockRollback), persisted)
            }
            if age <= policy.offlineGrace {
                return (status(for: persisted.lastResult), persisted)
            }
            return (.gateCheckRequired(.offlineGraceExpired), persisted)
        }
    }

    static func status(for result: GateCheckResult) -> GateStatus {
        switch result {
        case .clear:
            return .operational(openCases: [])
        case .caseOpen(let notices):
            return .operational(openCases: notices)
        case .banned(let state):
            return .banned(state)
        case .checkRequired(let reason):
            return .gateCheckRequired(reason)
        }
    }

    // MARK: - Read / stream

    public func currentStatus() -> GateStatus { cached }

    public nonisolated var snapshots: AsyncStream<GateStatus> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribe(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id: id) }
            }
        }
    }

    // MARK: - Private

    private func subscribe(id: UUID, continuation: AsyncStream<GateStatus>.Continuation) {
        continuations[id] = continuation
        continuation.yield(cached)
    }

    private func unsubscribe(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(cached)
        }
    }
}
