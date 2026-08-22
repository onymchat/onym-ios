import Foundation

/// HTTP client for the deployed push backend (`onym-push/apple`). One
/// base URL, one GET and two POSTs, JSON both ways.
///
/// Wire notes, pinned against `apple/src` of the reference:
/// - Request/response keys are camelCase; `Data` fields travel as
///   base64 strings and timestamps as RFC 3339 UTC seconds.
/// - Errors arrive as `{ "error": <code>, "message": <text> }` and
///   surface as `PushClientError.rejected` with the code verbatim.
/// - Session signatures are single-use server-side.
public struct URLSessionPushBackendClient: PushBackendClient {
    /// The deployed push backend for this interface.
    public static let defaultBaseURL = URL(string: "https://push.onym.app")!

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
        baseURL: URL = URLSessionPushBackendClient.defaultBaseURL,
        session: URLSession = URLSessionPushBackendClient.defaultSession
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func registrationKey() async throws -> Data {
        struct KeyResponse: Decodable {
            let publicKey: Data
        }
        let data = try await send(path: ["v1", "registration-key"], body: nil)
        let response: KeyResponse = try decode(data)
        return response.publicKey
    }

    public func register(_ request: PushRegisterRequest) async throws -> PushRegisterResponse {
        let body = try Self.encoder().encode(request)
        let data = try await send(path: ["v1", "register"], body: body)
        return try decode(data)
    }

    public func unregister(_ request: PushUnregisterRequest) async throws {
        let body = try Self.encoder().encode(request)
        _ = try await send(path: ["v1", "unregister"], body: body)
    }

    // MARK: - Transport

    private func send(path: [String], body: Data?) async throws -> Data {
        // https only, every build — matching the enforcement client. A
        // local reference deployment is reached through an https
        // proxy/tunnel, never by relaxing transport security here.
        let host = baseURL.host?.lowercased() ?? ""
        guard !host.isEmpty, baseURL.scheme?.lowercased() == "https" else {
            throw PushClientError.insecureBaseURL(baseURL.absoluteString)
        }
        let url = path.reduce(baseURL) { partial, component in
            partial.appending(path: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PushClientError.rejected(Self.rejection(http.statusCode, data))
        }
        return data
    }

    private static func rejection(_ statusCode: Int, _ data: Data) -> PushRejection {
        struct Envelope: Decodable {
            let error: String
            let message: String
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return PushRejection(
                statusCode: statusCode,
                rawCode: envelope.error,
                message: envelope.message
            )
        }
        return PushRejection(
            statusCode: statusCode,
            rawCode: "http_\(statusCode)",
            message: "the push backend rejected the request (HTTP \(statusCode))"
        )
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw PushClientError.malformedResponse("push backend response: \(error)")
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
