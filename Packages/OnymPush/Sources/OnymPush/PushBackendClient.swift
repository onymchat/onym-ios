import Foundation

/// A register call as the client presents it. Every field the
/// signature covers is transmitted (the APNs token inside the
/// envelope), so the backend can reconstruct the signed bytes and
/// actually verify — see `SignedPushSessionPayload`.
public struct PushRegisterRequest: Codable, Sendable, Equatable {
    /// Fresh `DCDevice` token, or nil when attestation is unavailable
    /// (simulator, enterprise build). The client never fabricates one.
    public let deviceToken: Data?
    public let userKey: String
    public let timestamp: Date
    /// User-key signature over `SignedPushSessionPayload.register`.
    public let signature: Data
    public let tokenEnvelope: PushTokenEnvelope
    public let subscriptions: [PushSubscription]

    public init(
        deviceToken: Data?,
        userKey: String,
        timestamp: Date,
        signature: Data,
        tokenEnvelope: PushTokenEnvelope,
        subscriptions: [PushSubscription]
    ) {
        self.deviceToken = deviceToken
        self.userKey = userKey
        self.timestamp = timestamp
        self.signature = signature
        self.tokenEnvelope = tokenEnvelope
        self.subscriptions = subscriptions
    }
}

public struct PushRegisterResponse: Codable, Sendable, Equatable {
    /// When this registration lapses unless refreshed — the client
    /// re-registers well before this while push stays enabled.
    public let expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }
}

public struct PushUnregisterRequest: Codable, Sendable, Equatable {
    public let deviceToken: Data?
    public let userKey: String
    public let timestamp: Date
    /// User-key signature over `SignedPushSessionPayload.unregister`.
    public let signature: Data
    public let tokenEnvelope: PushTokenEnvelope

    public init(
        deviceToken: Data?,
        userKey: String,
        timestamp: Date,
        signature: Data,
        tokenEnvelope: PushTokenEnvelope
    ) {
        self.deviceToken = deviceToken
        self.userKey = userKey
        self.timestamp = timestamp
        self.signature = signature
        self.tokenEnvelope = tokenEnvelope
    }
}

/// The push backend's refusal, kept verbatim: the service's error
/// vocabulary (`signature_invalid`, `relay_invalid`, `capacity`) is
/// what the caller branches on.
public struct PushRejection: Error, Sendable, Equatable {
    public let statusCode: Int
    public let rawCode: String
    public let message: String

    /// The typed reading of `rawCode`, for callers that branch —
    /// `.unknown` retains verbatim what a newer backend said, so no
    /// vocabulary growth is ever silently collapsed.
    public var code: PushErrorCode { PushErrorCode(rawCode: rawCode) }

    public init(statusCode: Int, rawCode: String, message: String) {
        self.statusCode = statusCode
        self.rawCode = rawCode
        self.message = message
    }
}

/// Stable error vocabulary emitted by the push backend — the shape of
/// the moderation package's `AuthorityErrorCode`, with an explicit
/// `unknown` arm because `rawCode` must survive codes this build has
/// never heard of.
public enum PushErrorCode: Sendable, Equatable {
    case signatureInvalid
    case relayInvalid
    case capacity
    case badRequest
    case internalError
    case unknown(String)

    public init(rawCode: String) {
        switch rawCode {
        case "signature_invalid": self = .signatureInvalid
        case "relay_invalid": self = .relayInvalid
        case "capacity": self = .capacity
        case "bad_request": self = .badRequest
        case "internal_error": self = .internalError
        default: self = .unknown(rawCode)
        }
    }
}

public enum PushClientError: Error, Sendable, Equatable {
    /// The base URL is not https — never relaxed, in any build.
    case insecureBaseURL(String)
    case invalidResponse
    case malformedResponse(String)
    case rejected(PushRejection)
}

/// The interface vendor's push backend — the relay watcher that turns
/// inbox-tagged events into content-free wakes. Production builds ship
/// `URLSessionPushBackendClient` against the deployed service; tests
/// use `StubPushBackendClient`.
public protocol PushBackendClient: Sendable {
    /// The X25519 key APNs tokens are encrypted to. Fetched before
    /// each register call so server-side rotation needs no release.
    func registrationKey() async throws -> Data

    /// Replace-all upsert of this device's subscription set. Session
    /// signatures are single-use server-side; a replay is refused 401.
    func register(_ request: PushRegisterRequest) async throws -> PushRegisterResponse

    /// Idempotent delete of this device's registration.
    func unregister(_ request: PushUnregisterRequest) async throws
}
