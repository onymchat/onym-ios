import Foundation

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
        /// Network failure / backend unreachable. NOT a backend
        /// refusal — a reachable backend answers `.checkRequired`.
        case unreachable
    }

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
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self, policy] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: UInt64(policy.interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Gate check

    /// Run one gate check now (launch, foreground, retry button).
    public func checkNow() async {
        guard let record = await moderation.activeMandateRecord() else {
            cached = .notMandated
            publish()
            return
        }

        let attempt = await performAttempt(for: record)
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
            let signature = try await signer.sign(
                GateCheckRequest.signedPayload(deviceToken: token, timestamp: timestamp)
            )
            let request = GateCheckRequest(
                deviceToken: token,
                userKey: record.mandate.user,
                mandateRef: try? record.mandate.mandateHash(),
                timestamp: timestamp,
                signature: signature
            )
            return .success(try await backend.gateCheck(request))
        } catch {
            return .unreachable
        }
    }

    // MARK: - Cadence arithmetic (pure)

    /// The profile-§5 rules as one pure function:
    /// - success → status from the result; persist `{result, now}`;
    /// - unreachable within `offlineGrace` of the last success → keep
    ///   serving the last known state;
    /// - unreachable past grace → `.gateCheckRequired(.offlineGraceExpired)`,
    ///   persisted state kept (a later success overwrites it);
    /// - unreachable with no history → `.gateCheckRequired(.neverChecked)`.
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
        case .unreachable:
            guard let persisted else {
                return (.gateCheckRequired(.neverChecked), nil)
            }
            if now.timeIntervalSince(persisted.lastSuccessAt) <= policy.offlineGrace {
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
