import Foundation

/// The interface's countersignature over the mandate the user signed
/// (Moderation.md §5.3). Deliberately just the signature: the client
/// appends it to its own copy, so the countersigning round-trip cannot
/// change any consented field.
public struct InterfaceCountersignature: Codable, Sendable, Equatable {
    /// Base64 detached signature over the mandate's `signingBytes()`.
    public let signature: String

    public init(signature: String) {
        self.signature = signature
    }
}

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

/// First-session enrollment as the client presents it. Every field the
/// signature covers is transmitted, so the backend can reconstruct the
/// signed bytes and actually verify — see `signedPayload`.
public struct EnrollmentRequest: Codable, Sendable, Equatable {
    /// Fresh `DCDevice` token, or nil when attestation is unavailable.
    /// The client never fabricates one.
    public let deviceToken: Data?
    public let userKey: String
    public let timestamp: Date
    /// User-key signature over `signedPayload(deviceToken:userKey:timestamp:)`.
    public let signature: Data

    public init(deviceToken: Data?, userKey: String, timestamp: Date, signature: Data) {
        self.deviceToken = deviceToken
        self.userKey = userKey
        self.timestamp = timestamp
        self.signature = signature
    }

    /// The bytes the user key signs, built from **exactly** the fields
    /// this request transmits — the backend recomputes this from what
    /// it received. Length-prefixed so no field boundary is ambiguous.
    /// PROVISIONAL until the enforcement backend's wire contract is
    /// specified.
    public static func signedPayload(deviceToken: Data?, userKey: String, timestamp: Date) -> Data {
        SignedSessionPayload.bytes(
            context: "onym-moderation-enroll-v1",
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            mandateRef: nil
        )
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

    /// The bytes the user key signs, built from **exactly** the fields
    /// this request transmits — `mandateRef` included, so a signature
    /// can't be replayed against a different mandate. PROVISIONAL until
    /// the enforcement backend's wire contract is specified.
    public static func signedPayload(
        deviceToken: Data?,
        userKey: String,
        mandateRef: String?,
        timestamp: Date
    ) -> Data {
        SignedSessionPayload.bytes(
            context: "onym-moderation-gate-v1",
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            mandateRef: mandateRef
        )
    }
}

/// Shared construction for the session payloads the user key signs.
/// Every field is length-prefixed and the payload is domain-separated
/// by `context`, so no two field layouts can collide and an enrollment
/// signature can never be replayed as a gate-check signature.
enum SignedSessionPayload {
    static func bytes(
        context: String,
        deviceToken: Data?,
        userKey: String,
        timestamp: Date,
        mandateRef: String?
    ) -> Data {
        var payload = Data()
        append(&payload, Data(context.utf8))
        append(&payload, deviceToken ?? Data())
        append(&payload, Data(userKey.utf8))
        append(&payload, Data(ISO8601DateFormatter.moderation.string(from: timestamp).utf8))
        append(&payload, Data((mandateRef ?? "").utf8))
        return payload
    }

    /// Big-endian 32-bit length prefix, so concatenation is injective.
    private static func append(_ payload: inout Data, _ field: Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(field)
    }
}

extension ISO8601DateFormatter {
    /// One formatter configuration for signed payloads — the default
    /// `ISO8601DateFormatter()` options are the stable subset (no
    /// fractional seconds), pinned here so the signed bytes can't shift
    /// with a caller's formatter settings.
    static let moderation: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
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
    /// Client-derived (never sent by the backend): the backend was
    /// reachable and deterministically refused the session — a
    /// replayed or invalid signature (401/403). Retrying with a fresh
    /// session usually clears it; a persistent refusal points at the
    /// device clock being outside the server's freshness window.
    case backendRefused
    /// Client-derived: the backend answered `no_mandate` — its record
    /// of this device's enrollment/mandate is gone (state loss,
    /// redeploy, or a mandate never countersigned). Not user-transient:
    /// the recovery is consenting again, which re-runs enrollment,
    /// countersignature, and registration — the gate flow routes this
    /// state back to consent rather than to a retry that cannot succeed.
    case enrollmentLost
    /// Local policy: the device clock now reads earlier than the last
    /// successful check, so elapsed time can't be trusted to bound
    /// staleness — the grace window is refused rather than extended.
    case clockRollback
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
/// write/read path for device marks. Production builds ship
/// `URLSessionEnforcementBackendClient` against the deployed service;
/// UI-test builds keep `StubEnforcementBackendClient` for
/// scenario-driven gates.
///
/// One protocol for enrollment, countersignature, and gate check
/// because all three are the same service sharing auth and transport.
public protocol EnforcementBackendClient: Sendable {
    /// First-session enrollment at mandate signing: the (identity
    /// signature, device token) pair is the only token↔enrollment
    /// linkage. Returns the vendor-local `deviceBinding` the mandate
    /// will carry.
    func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment

    /// Interface countersignature over the user-signed mandate
    /// (Moderation.md §5.3 — signed by the user, countersigned by
    /// the interface).
    ///
    /// Returns **only the interface's signature**, never a rebuilt
    /// mandate: the object the user signed is the consent record, and
    /// handing back a full mandate would let a buggy or compromised
    /// backend alter fields the user's signature no longer covers.
    func countersignMandate(_ mandate: ModerationMandate) async throws -> InterfaceCountersignature

    /// The launch/interval gate check (profile §5).
    func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult
}
