import Foundation

/// HTTP client for the interface vendor's enforcement backend (the
/// deployed reference `apple` service): enrollment, mandate
/// countersignature, and the gate check. One base URL, three POSTs,
/// JSON both ways.
///
/// Wire notes, pinned against `apple/src` of the reference:
/// - Request/response keys are camelCase; `Data` fields travel as
///   base64 strings and timestamps as RFC 3339 UTC seconds — exactly
///   what Foundation's `.iso8601` strategies produce, so the encoder
///   below is standard.
/// - The countersign body is the mandate JSON itself; the server
///   recomputes the canonical signing bytes from the raw body, so any
///   field-faithful encoding verifies. `ModerationCanonicalEncoder`
///   is used anyway so the transmitted bytes are deterministic.
/// - `GateCheckResult` is serialized by the server in Swift's own
///   synthesized-enum shape (`{"caseOpen":{"_0":[…]}}`) precisely so
///   this client can decode it with a plain `JSONDecoder`.
/// - Session signatures are single-use server-side; a replayed
///   enrollment/gate-check signature is refused with 401. The signed
///   payloads (`onym-moderation-enroll-v1` / `onym-moderation-gate-v1`)
///   are built by the request types' `signedPayload` helpers — the
///   caller signs, this client only transports.
/// - Errors arrive as `{ "error": <code>, "message": <text> }`; they
///   surface as `AuthorityClientError.rejected` with the raw code kept
///   verbatim (the apple service's vocabulary — `no_mandate`,
///   `verdict_not_yet_valid`, `mark_write_failed` — is broader than
///   the authority's).
public struct URLSessionEnforcementBackendClient: EnforcementBackendClient {
    /// The deployed enforcement backend for this interface.
    public static let defaultBaseURL = URL(string: "https://moderation.onym.app")!

    private let baseURL: URL
    private let session: URLSession

    /// Ephemeral and cookie-less: session state that outlives a
    /// request is linkable surface this codebase avoids everywhere.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    public init(
        baseURL: URL = URLSessionEnforcementBackendClient.defaultBaseURL,
        session: URLSession = URLSessionEnforcementBackendClient.defaultSession
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func enrollDevice(_ request: EnrollmentRequest) async throws -> DeviceEnrollment {
        let body = try Self.encoder().encode(request)
        let data = try await send(path: ["v1", "enroll"], body: body)
        return try decode(data)
    }

    public func countersignMandate(
        _ mandate: ModerationMandate
    ) async throws -> InterfaceCountersignature {
        let body = try ModerationCanonicalEncoder.encode(mandate)
        let data = try await send(path: ["v1", "mandates", "countersign"], body: body)
        return try decode(data)
    }

    public func gateCheck(_ request: GateCheckRequest) async throws -> GateCheckResult {
        let body = try Self.encoder().encode(request)
        let data = try await send(path: ["v1", "gate-check"], body: body)
        return try decode(data)
    }

    /// Redeem a moderator-issued recovery grant. The grant travels as
    /// its exact signed bytes (base64 via `Data`'s default coding);
    /// the session envelope binds the grant's reference, so this
    /// signature presents this grant and nothing else.
    public func recover(_ request: RecoveryRequest) async throws -> RecoveryResult {
        let body = try Self.encoder().encode(request)
        let data = try await send(path: ["v1", "recover"], body: body)
        return try decode(data)
    }

    // MARK: - Transport

    private func send(path: [String], body: Data) async throws -> Data {
        // https only, every build — matching the authority client. A
        // local reference deployment is reached through an https
        // proxy/tunnel, never by relaxing transport security here.
        let host = baseURL.host?.lowercased() ?? ""
        guard !host.isEmpty, baseURL.scheme?.lowercased() == "https" else {
            throw AuthorityClientError.insecureBaseURL(baseURL.absoluteString)
        }
        let url = path.reduce(baseURL) { partial, component in
            partial.appending(path: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthorityClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthorityClientError.rejected(Self.rejection(http.statusCode, data))
        }
        return data
    }

    private static func rejection(_ statusCode: Int, _ data: Data) -> AuthorityRejection {
        struct Envelope: Decodable {
            let error: String
            let message: String
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return AuthorityRejection(
                statusCode: statusCode,
                rawCode: envelope.error,
                message: envelope.message
            )
        }
        return AuthorityRejection(
            statusCode: statusCode,
            rawCode: "http_\(statusCode)",
            message: "the enforcement backend rejected the request (HTTP \(statusCode))"
        )
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try ModerationJSON.decoder().decode(Value.self, from: data)
        } catch {
            throw AuthorityClientError.malformedResponse(
                "enforcement backend response: \(error)"
            )
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
