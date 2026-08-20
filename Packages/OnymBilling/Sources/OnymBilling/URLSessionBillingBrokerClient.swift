import CryptoKit
import Foundation
import OnymFoundation

/// HTTP client for the publisher's billing broker.
///
/// Same posture as every other client here: https in all builds,
/// ephemeral cookie-less session, bounded bodies, `{"error","message"}`
/// refusals mapped onto a domain vocabulary with the broker's own code
/// kept when we do not model it.
public struct URLSessionBillingBrokerClient: BillingBrokerClient {
    public static let defaultBaseURL = URL(string: "https://billing.onym.app")!

    private let baseURL: URL
    private let session: URLSession
    /// The broker's issuer key, pinned from the operator's manifest.
    ///
    /// Required, not optional. It was optional, and when it was nil the
    /// signature went unchecked while the epoch came back looking
    /// exactly like a verified one — which is precisely the "anyone who
    /// can answer this URL revokes a person's storage" case the check
    /// exists to prevent, arrived at by leaving a default alone.
    private let issuerKey: Curve25519.Signing.PublicKey

    static let maxResponseBytes = 8 << 20

    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    public init(
        baseURL: URL = URLSessionBillingBrokerClient.defaultBaseURL,
        session: URLSession = URLSessionBillingBrokerClient.defaultSession,
        issuerKey: Curve25519.Signing.PublicKey
    ) {
        self.baseURL = baseURL
        self.session = session
        self.issuerKey = issuerKey
    }

    public func issueEntitlement(_ request: SeatEntitlementRequest) async throws -> Data {
        try await submit(request, path: ["v1", "entitlements"])
    }

    public func refreshEntitlement(_ request: SeatEntitlementRequest) async throws -> Data {
        try await submit(request, path: ["v1", "entitlements", "refresh"])
    }

    public func revocationEpoch() async throws -> RevocationEpoch {
        let data = try await send(method: "GET", path: ["v1", "revocations", "current"], body: nil)
        struct Wire: Decodable {
            let epoch: Int
            let publishedAt: Date
            let revoked: [String]
            let signature: String
        }
        guard
            let wire = try? Self.decoder.decode(Wire.self, from: data),
            let signature = Data(base64Encoded: wire.signature)
        else {
            throw BillingError.brokerRejected(code: "malformed_epoch", message: nil)
        }
        // An unverifiable epoch is not an epoch.
        let signingBytes = try ServiceManifestCanonical.signingBytes(
            of: data, omitting: ["signature"])
        guard issuerKey.isValidSignature(signature, for: signingBytes) else {
            throw BillingError.signatureInvalid
        }
        return RevocationEpoch(
            epoch: wire.epoch,
            publishedAt: wire.publishedAt,
            revoked: Set(wire.revoked),
            rawBytes: data,
            signature: signature
        )
    }

    // MARK: - Transport

    private func submit(_ request: SeatEntitlementRequest, path: [String]) async throws -> Data {
        struct Body: Encodable {
            let version = 1
            let offerId: String
            let audience: String
            let subject: String
            let sealTo: Data
            let signedTransactionInfo: String
            let timestamp: Date
        }
        let body = try Self.encoder.encode(
            Body(
                offerId: request.offerId,
                audience: request.audience,
                subject: request.subject,
                sealTo: request.sealTo,
                signedTransactionInfo: request.signedTransaction,
                timestamp: Date()
            )
        )
        let data = try await send(method: "POST", path: path, body: body)
        struct Response: Decodable { let sealedEntitlement: Data }
        guard let response = try? Self.decoder.decode(Response.self, from: data) else {
            throw BillingError.brokerRejected(code: "malformed_response", message: nil)
        }
        return response.sealedEntitlement
    }

    private func send(method: String, path: [String], body: Data?) async throws -> Data {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host(), !host.isEmpty
        else {
            throw BillingError.brokerUnavailable
        }
        let url = path.reduce(baseURL) { $0.appending(path: $1) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BillingError.brokerUnavailable
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(1 << 16)
        for try await byte in stream {
            bytes.append(byte)
            if bytes.count > Self.maxResponseBytes { throw BillingError.brokerUnavailable }
        }
        let data = Data(bytes)
        guard (200..<300).contains(http.statusCode) else {
            struct Envelope: Decodable {
                let error: String
                let message: String?
            }
            if let envelope = try? Self.decoder.decode(Envelope.self, from: data) {
                throw BillingError.brokerRejected(code: envelope.error, message: envelope.message)
            }
            throw BillingError.brokerRejected(code: "http_\(http.statusCode)", message: nil)
        }
        return data
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
