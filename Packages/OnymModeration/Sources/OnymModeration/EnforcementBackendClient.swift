import Foundation

/// The vendor-local enrollment identifier the mandate's
/// `deviceBinding` carries. Issued by the backend — never derived
/// from DeviceCheck tokens, which are ephemeral and unlinkable, so no
/// global device identifier is ever created (profile §5).
public struct DeviceEnrollment: Codable, Sendable, Equatable {
    public let deviceBinding: String

    public init(deviceBinding: String) {
        self.deviceBinding = deviceBinding
    }
}

/// One gate check as the client presents it: a fresh device token and
/// an identity signature in the same session — the profile's only
/// permitted token↔enrollment linkage, refreshed every session.
public struct GateCheckRequest: Codable, Sendable, Equatable {
    /// Fresh `DCDevice` token, or nil when attestation is unavailable
    /// (simulator, enterprise build). The client NEVER fabricates a
    /// token; a conforming backend never answers `.clear` to a nil
    /// token (see `StubEnforcementBackendClient` for the one exception
    /// and why).
    public let deviceToken: Data?
    public let userKey: String
    /// Hash of the active mandate, when one exists.
    public let mandateRef: String?
    public let timestamp: Date
    /// User-key signature binding token and timestamp into this
    /// session. PROVISIONAL signing form — see
    /// `GateCheckRequest.signedPayload`.
    public let signature: Data

    public init(deviceToken: Data?, userKey: String, mandateRef: String?, timestamp: Date, signature: Data) {
        self.deviceToken = deviceToken
        self.userKey = userKey
        self.mandateRef = mandateRef
        self.timestamp = timestamp
        self.signature = signature
    }

    /// The bytes the user key signs: the token (empty when absent)
    /// followed by the ISO 8601 timestamp. PROVISIONAL until the
    /// enforcement backend's wire contract is specified.
    public static func signedPayload(deviceToken: Data?, timestamp: Date) -> Data {
        var payload = deviceToken ?? Data()
        payload.append(Data(ISO8601DateFormatter().string(from: timestamp).utf8))
        return payload
    }
}

/// Why the backend (or local policy) demands a successful gate check
/// before the app may operate.
public enum CheckRequiredReason: String, Codable, Sendable, Equatable {
    /// The presented token failed Apple-side validation.
    case tokenInvalid
    /// No attestation path on this device/build (simulator,
    /// enterprise-signed) — profile §8.5 fails these toward
    /// gate-check-required.
    case attestationUnavailable
    /// Bits are set but the session identity resolves no active
    /// verdict — the holder is routed to the authority's
    /// re-identification / new-holder procedure (profile §5).
    case reidentificationRequired
    /// Local policy: the offline grace window lapsed with no
    /// successful check.
    case offlineGraceExpired
    /// Local policy: no successful check has ever completed.
    case neverChecked
}

/// The ban state a gate check returns for display. The client renders
/// this; it never computes ban state itself — the bits (read by the
/// backend) are the sole authority, which is what survives reinstall.
public struct BanState: Codable, Sendable, Equatable {
    /// Hash of the governing verdict.
    public let verdictRef: String
    /// The verdict itself when the backend serves it; validated
    /// client-side (`VerdictValidator`) before display.
    public let verdict: Verdict?
    public let authorityContact: String
    /// Nil means permanent (appealable at the manifest's appellate
    /// for as long as it is in force).
    public let banExpires: Date?
    public let appealURL: URL?
    /// The new-holder procedure — mandatory in the ban UX (a silent
    /// brick is nonconforming, profile §5).
    public let newHolderURL: URL?

    public init(
        verdictRef: String,
        verdict: Verdict? = nil,
        authorityContact: String,
        banExpires: Date? = nil,
        appealURL: URL? = nil,
        newHolderURL: URL? = nil
    ) {
        self.verdictRef = verdictRef
        self.verdict = verdict
        self.authorityContact = authorityContact
        self.banExpires = banExpires
        self.appealURL = appealURL
        self.newHolderURL = newHolderURL
    }
}

/// What the enforcement backend answered for this device, after
/// reading the DeviceCheck bits and reconciling verdict state
/// (profile §5–§6).
public enum GateCheckResult: Codable, Sendable, Equatable {
    /// Both bits clear (or never set — Apple's "bit state not found"
    /// is the clean state).
    case clear
    /// bit0: operate normally, display the open case(s).
    case caseOpen([CaseNotice])
    /// bit1: refuse to operate, show the full ban UX.
    case banned(BanState)
    /// No trustworthy answer: re-present a token, or route to
    /// re-identification.
    case checkRequired(CheckRequiredReason)
}

/// The interface vendor's enforcement backend — the only party
/// holding the Apple DeviceCheck key, therefore the only possible
/// write/read path for device marks. Not deployed yet: the app ships
/// against `StubEnforcementBackendClient`, and a future
/// `URLSessionEnforcementBackendClient` (SEPContractTransport-style
/// wire client) slots in behind this protocol untouched.
///
/// One protocol for enrollment, countersignature, and gate check
/// because all three are the same service sharing auth and transport.
public protocol EnforcementBackendClient: Sendable {
    /// First-session enrollment at mandate signing: the (identity
    /// signature, device token) pair is the only token↔enrollment
    /// linkage. Returns the vendor-local `deviceBinding` the mandate
    /// will carry.
    func enrollDevice(token: Data?, userKey: String, signature: Data) async throws -> DeviceEnrollment

    /// Interface countersignature over the user-signed mandate
    /// (Moderation.md §5.3 — signed by the user, countersigned by
    /// the interface).
    func countersignMandate(_ mandate: ModerationMandate) async throws -> ModerationMandate

    /// The launch/interval gate check (profile §5).
    func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult
}
