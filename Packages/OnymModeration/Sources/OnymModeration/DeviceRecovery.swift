import CryptoKit
import Foundation

// Device recovery (REFERENCE-AUTHORITY-POLICY §6): the way back for a
// marked device whose enrolled identity did not survive a reinstall or
// a change of hands. There is deliberately no self-serve path — the
// holder files a claim carrying a real contact and their own account
// of how they hold the device, a human moderator at the authority
// decides it, and only the grant that decision signs can move the
// case's record at the enforcement backend.

// MARK: - The grant

/// A moderator-issued recovery grant, held as the **exact bytes** the
/// authority signed. They travel verbatim: the operator signature is
/// over the canonical form of these bytes, so re-encoding them would
/// orphan it.
public struct RecoveryGrant: Sendable, Equatable {
    public let raw: Data
    /// The wire's `grantVersion`; the authority defaults an absent one
    /// to 1, and so does this decode (`RecoveryGrant` in
    /// `apple/src/types.rs`, `#[serde(default = "one")]`).
    public let version: Int
    public let caseId: String
    /// The identity key the grant was issued to. The enforcement
    /// backend refuses a session by any other key, so a stolen grant
    /// is inert.
    public let grantee: String
    public let authority: String
    public let issuedAt: String

    public init(raw: Data) throws {
        struct Wire: Decodable {
            let grantVersion: Int?
            let caseId, grantee, authority, issuedAt, signature: String
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: raw)
        } catch {
            throw ModerationError.grantInvalid("recovery grant: \(error)")
        }
        // Refuse a version this client does not implement, by name —
        // the version is inside the signed bytes, so presenting a v2
        // grant through v1 assumptions could only fail at the backend
        // with an opaque session rejection. The interface refuses the
        // same way (`enforcement.rs`, "unsupported grantVersion").
        let version = wire.grantVersion ?? 1
        guard version == 1 else {
            throw ModerationError.grantInvalid(
                "unsupported recovery grant version \(version); this client implements 1"
            )
        }
        self.raw = raw
        self.version = version
        self.caseId = wire.caseId
        self.grantee = wire.grantee
        self.authority = wire.authority
        self.issuedAt = wire.issuedAt
    }

    /// The grant's reference: SHA-256 over the canonical signing bytes
    /// (every field except `signature`, sorted keys). The enforcement
    /// backend derives the same value from the raw bytes to make the
    /// grant single-use, and the session signature binds it — so the
    /// two derivations must agree. Reconstructed through a typed
    /// mirror, like `Verdict.signingBytes()`: JSONEncoder's
    /// `.sortedKeys` is UTF-8 byte order, matching serde's map order.
    /// A grant carrying fields this mirror doesn't know would derive a
    /// different reference and fail the session — acceptable, since
    /// grants are consumed by the interface whose vocabulary this is.
    public func reference() throws -> String {
        struct Unsigned: Encodable {
            let grantVersion: Int
            let caseId, grantee, authority, issuedAt: String
        }
        let bytes = try ModerationCanonicalEncoder.encode(
            Unsigned(
                grantVersion: version,
                caseId: caseId,
                grantee: grantee,
                authority: authority,
                issuedAt: issuedAt
            )
        )
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Redemption at the enforcement backend

/// `POST /v1/recover` as the client presents it: the grant's exact
/// bytes plus the same session envelope as a gate check, signed by the
/// grantee identity with the grant's reference bound into the payload.
public struct RecoveryRequest: Codable, Sendable, Equatable {
    public let deviceToken: Data?
    public let userKey: String
    /// The grant's exact signed bytes; travels as base64.
    public let grant: Data
    public let timestamp: Date
    public let signature: Data

    public init(deviceToken: Data?, userKey: String, grant: Data, timestamp: Date, signature: Data) {
        self.deviceToken = deviceToken
        self.userKey = userKey
        self.grant = grant
        self.timestamp = timestamp
        self.signature = signature
    }

    /// Same five-field layout as the other session payloads, with the
    /// grant reference in the trailing slot — one signature presents
    /// one grant, and can be replayed against no other endpoint.
    public static func signedPayload(
        deviceToken: Data?,
        userKey: String,
        grantRef: String,
        timestamp: Date
    ) -> Data {
        SignedSessionPayload.bytes(
            context: "onym-moderation-recover-v1",
            deviceToken: deviceToken,
            userKey: userKey,
            timestamp: timestamp,
            mandateRef: grantRef
        )
    }
}

/// What redemption answered. `recovered` carries the gate result the
/// backend's reconciliation produced — no second round trip decides
/// whether the device is usable. `markInForce` means a record still
/// bans the device (the case's, or the claimant's own); nothing moved,
/// the grant was not consumed, and the routes point back at the
/// authority.
public enum RecoveryResult: Sendable, Equatable {
    case recovered(GateCheckResult)
    case markInForce(authorityContact: String, newHolderURL: URL?, appealURL: URL?)
}

extension RecoveryResult: Decodable {
    // This is deliberately the exact `{status, …}` tagged shape the
    // merged reference interface serializes (`RecoveryResult` in
    // `apple/src/types.rs`, onym-moderation#27): `recovered` carries
    // `gate`, `markInForce` carries the contact and optional routes.
    private enum CodingKeys: String, CodingKey {
        case status, gate, authorityContact, newHolderUrl, appealUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "recovered":
            self = .recovered(try container.decode(GateCheckResult.self, forKey: .gate))
        case "markInForce":
            self = .markInForce(
                authorityContact: try container.decode(String.self, forKey: .authorityContact),
                newHolderURL: try container.decodeIfPresent(URL.self, forKey: .newHolderUrl),
                appealURL: try container.decodeIfPresent(URL.self, forKey: .appealUrl)
            )
        case let other:
            // A DecodingError, not a ModerationError: the real client
            // wraps every decode failure into
            // `AuthorityClientError.malformedResponse`, and an unknown
            // status is exactly that — a response this decode does not
            // speak — not a defect in the grant.
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "unknown recovery status '\(other)'"
            )
        }
    }
}

extension EnforcementBackendClient {
    /// Redeem a moderator-issued recovery grant. Default refuses so
    /// existing conformers (fakes, the UI-test stub's scenarios that
    /// never reach recovery) stay source-compatible; real backends
    /// override.
    public func recover(_ request: RecoveryRequest) async throws -> RecoveryResult {
        throw ModerationError.notImplemented("recover")
    }
}

// MARK: - The claim, at the authority

/// Where a filed claim stands. The authority answers this only to the
/// key the claim names.
public struct RecoveryClaimStatus: Sendable, Equatable {
    /// `open` | `granted` | `refused`.
    public let state: String
    /// The moderator's reasons, once decided.
    public let reasoning: String?
    /// The signed grant, present exactly when `state == "granted"`.
    public let grant: RecoveryGrant?

    public init(state: String, reasoning: String?, grant: RecoveryGrant?) {
        self.state = state
        self.reasoning = reasoning
        self.grant = grant
    }
}

extension ModerationAuthorityClient {
    /// File a device-recovery claim: a real contact for the moderator
    /// to verify the holder through, and the holder's own account of
    /// how they came to hold the marked device. Returns the claim id
    /// to poll. Default refuses so existing conformers stay
    /// source-compatible.
    public func fileRecoveryClaim(contact: String, statement: String) async throws -> String {
        throw ModerationError.notImplemented("file-recovery-claim")
    }

    public func recoveryClaimStatus(claimId: String) async throws -> RecoveryClaimStatus {
        throw ModerationError.notImplemented("recovery-claim-status")
    }
}

// MARK: - Claim persistence

/// The one pending claim id, kept across launches so the gate screen
/// resumes polling instead of asking the holder to file again. Scoped
/// to the grantee key the claim was signed by: the authority answers
/// a claim only to that key, so a claim resumed under a different
/// identity could never be polled — it must read as "no claim".
public protocol RecoveryClaimStore: Sendable {
    func load(grantee: String) -> String?
    func save(_ claimId: String?, grantee: String)
}

/// `@unchecked Sendable` for the same reason as
/// `UserDefaultsGateStateStore`: `UserDefaults` is documented
/// thread-safe but not formally `Sendable`.
public struct UserDefaultsRecoveryClaimStore: RecoveryClaimStore, @unchecked Sendable {
    private static let claimKey = "app.onym.ios.moderation.recoveryClaim"
    private static let granteeKey = "app.onym.ios.moderation.recoveryClaimGrantee"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(grantee: String) -> String? {
        guard defaults.string(forKey: Self.granteeKey) == grantee else {
            return nil
        }
        return defaults.string(forKey: Self.claimKey)
    }

    public func save(_ claimId: String?, grantee: String) {
        guard let claimId else {
            defaults.removeObject(forKey: Self.claimKey)
            defaults.removeObject(forKey: Self.granteeKey)
            return
        }
        defaults.set(claimId, forKey: Self.claimKey)
        defaults.set(grantee, forKey: Self.granteeKey)
    }
}

// MARK: - Redemption through the gate repository

/// What redeeming a grant did to the gate, in terms the UI acts on.
public enum RecoveryRedemption: Sendable, Equatable {
    /// The record moved and reconciliation ran; the gate now shows
    /// this. `.operational` means the device is usable again.
    case recovered(GateStatus)
    /// A record still bans the device; the grant survives for after
    /// the authority resolves it.
    case markInForce(authorityContact: String, newHolderURL: URL?, appealURL: URL?)
    case failed(String)
}

