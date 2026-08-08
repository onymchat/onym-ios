import Foundation

/// Stub enforcement backend — no real backend is deployed (the Apple
/// DeviceCheck key doesn't exist yet), so this keeps the whole client
/// rail exercisable: enrollment issues a stable local identifier,
/// countersigning appends a sentinel that can never verify, and the
/// gate check answers a canned scenario.
///
/// HONESTY RULE: this stub is the only implementation allowed to
/// answer `.clear` to a nil-token gate check. There is no live
/// moderation to evade yet, and blocking every simulator run would
/// make the app undevelopable. A real `EnforcementBackendClient` must
/// answer `.checkRequired(.attestationUnavailable)` instead —
/// nil token never means unmoderated operation (profile §8.5).
public struct StubEnforcementBackendClient: EnforcementBackendClient, @unchecked Sendable {
    /// Which canned world the stub simulates. Chosen by whoever
    /// constructs the client; nothing reads a launch argument yet — PR-3
    /// wires the app and will supply the scenario from
    /// `--moderation-scenario` in DEBUG builds (the raw values here are
    /// that argument's vocabulary).
    public enum Scenario: String, Sendable {
        case clear
        case caseOpen = "case-open"
        case banned
        case checkRequired = "check-required"
    }

    /// Sentinel appended by `countersignMandate`. Deliberately not a
    /// signature: any record carrying it stays `countersigned: false`
    /// so a stub mandate can never pass as spec-valid.
    public static let countersignSentinel = "stub:interface-unsigned"

    private static let bindingKey = "app.onym.ios.moderation.stub.deviceBinding"

    /// Serializes the read-then-write in `enrollDevice`. Without it two
    /// concurrent enrollments can both miss the stored value and mint
    /// different bindings, and the caller that loses the write walks away
    /// with a mandate bound to a `deviceBinding` nothing persisted.
    private static let bindingLock = NSLock()

    private let scenario: Scenario
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    public init(
        scenario: Scenario = .clear,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.scenario = scenario
        self.defaults = defaults
        self.now = now
    }

    /// Stable across calls — an enrollment identifier that churns
    /// would sever every mandate's `deviceBinding` on next launch. The
    /// check-then-store is taken under `bindingLock` so concurrent
    /// enrollments all observe the same binding.
    public func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
        Self.bindingLock.lock()
        defer { Self.bindingLock.unlock() }
        if let existing = defaults.string(forKey: Self.bindingKey) {
            return DeviceEnrollment(deviceBinding: existing)
        }
        let binding = "stub-enrollment:\(UUID().uuidString)"
        defaults.set(binding, forKey: Self.bindingKey)
        return DeviceEnrollment(deviceBinding: binding)
    }

    public func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature {
        InterfaceCountersignature(signature: Self.countersignSentinel)
    }

    public func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult {
        switch scenario {
        case .clear:
            return .clear
        case .caseOpen:
            return .caseOpen([Self.fixtureNotice(for: request, now: now())])
        case .banned:
            return .banned(Self.fixtureBanState(for: request, now: now()))
        case .checkRequired:
            return .checkRequired(.attestationUnavailable)
        }
    }

    // MARK: - Fixtures

    /// Canned case notice shaped like a real one so the banner and
    /// detail UI render meaningfully in every scenario run.
    static func fixtureNotice(for request: GateCheckRequest, now: Date) -> CaseNotice {
        CaseNotice(
            caseId: "stub-case-1",
            authority: "onym:component:stub-authority",
            accused: request.userKey,
            mandateRef: request.mandateRef ?? "stub-mandate",
            classId: "unsolicited-pornography",
            evidenceSummary: "stub-evidence-hash",
            responseDeadline: now.addingTimeInterval(7 * 86_400),
            decisionDeadline: now.addingTimeInterval(14 * 86_400),
            signature: "stub:authority-unsigned"
        )
    }

    /// Canned ban with the full display surface: verdict reference,
    /// authority contact, expiry, appeal and new-holder paths.
    ///
    /// The dates model an executed **suspensive** P90D ban with a P30D
    /// appeal window, so the fixture satisfies `VerdictValidator`'s
    /// derived-deadline rules rather than merely rendering: decided 40
    /// days ago, appeal window lapsed 10 days ago, execution began
    /// there, expiry is execution + the consented term.
    static func fixtureBanState(for request: GateCheckRequest, now: Date) -> BanState {
        let decidedAt = now.addingTimeInterval(-40 * 86_400)
        let appealDeadline = decidedAt.addingTimeInterval(30 * 86_400)
        let verdict = Verdict(
            caseId: "stub-case-1",
            authority: "onym:component:stub-authority",
            mandateRef: request.mandateRef ?? "stub-mandate",
            accusedKeys: [request.userKey],
            deviceBinding: "stub-enrollment",
            classId: "unsolicited-pornography",
            disposition: .ban,
            marks: Marks(caseOpen: false, banned: true),
            banExpires: appealDeadline.addingTimeInterval(90 * 86_400),
            executeAfter: appealDeadline,
            reasoning: "stub-reasoning-hash",
            appealDeadline: appealDeadline,
            decidedAt: decidedAt,
            signature: "stub:authority-unsigned",
            isFinal: false
        )
        return BanState(
            verdictRef: "stub-verdict-hash",
            verdict: verdict,
            authorityContact: "appeals@stub-authority.example",
            banExpires: verdict.banExpires,
            appealURL: URL(string: "https://stub-authority.example/appeal"),
            newHolderURL: URL(string: "https://stub-authority.example/new-holder")
        )
    }
}
