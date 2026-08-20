import CryptoKit
import Foundation
import OnymFoundation

extension URLSessionBackupClient {
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

    func decode<Value: Decodable>(_ data: Data) throws -> Value {
        guard let value = try? Self.decoder.decode(Value.self, from: data) else {
            throw BackupError.rejected(code: "malformed_response", message: nil)
        }
        return value
    }

    func get(
        path: [String],
        signed: Bool,
        maxResponseBytes: Int = URLSessionBackupClient.maxJSONResponseBytes
    ) async throws -> Data {
        try await send(
            method: "GET", path: path, body: Data(), contentType: nil,
            signed: signed, maxResponseBytes: maxResponseBytes
        )
    }

    func get(url: URL, signed: Bool) async throws -> Data {
        try await send(
            method: "GET", url: url, body: Data(), contentType: nil,
            signed: signed, maxResponseBytes: Self.maxJSONResponseBytes
        )
    }

    func post(path: [String], body: Data) async throws -> Data {
        try await send(
            method: "POST", path: path, body: body, contentType: "application/json",
            signed: true, maxResponseBytes: Self.maxJSONResponseBytes
        )
    }

    func send(
        method: String,
        path: [String],
        body: Data,
        contentType: String?,
        signed: Bool,
        maxResponseBytes: Int
    ) async throws -> Data {
        let url = path.reduce(endpoint) { $0.appending(path: $1) }
        return try await send(
            method: method, url: url, body: body, contentType: contentType,
            signed: signed, maxResponseBytes: maxResponseBytes
        )
    }

    func send(
        method: String,
        url: URL,
        body: Data,
        contentType: String?,
        signed: Bool,
        maxResponseBytes: Int
    ) async throws -> Data {
        let request = try await makeRequest(
            method: method, url: url, body: body, contentType: contentType, signed: signed
        )
        let (data, response) = try await perform(request, maxResponseBytes: maxResponseBytes)
        try Self.check(response, data)
        return data
    }

    /// Build a request and, when the route requires it, sign it.
    ///
    /// The signature covers the method, the path *with its query*, and a
    /// digest of the body — so nothing about the request can be moved
    /// after signing without invalidating it.
    func makeRequest(
        method: String,
        url: URL,
        body: Data,
        contentType: String?,
        signed: Bool
    ) async throws -> URLRequest {
        // https in every build. A local operator is reached through a
        // tunnel, never by relaxing transport security here.
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else {
            throw BackupError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if !body.isEmpty { request.httpBody = body }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard signed else { return request }
        let signedPath = url.path() + (url.query().map { "?\($0)" } ?? "")
        for (field, value) in try BackupAccessProof.headers(
            method: method, path: signedPath, body: body, material: material
        ) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Presented only where one exists. An operator with no declared
        // issuers never sees this header, which is the self-hosting
        // path.
        if let credential = await entitlement() {
            request.setValue(credential.base64EncodedString(), forHTTPHeaderField: "X-Onym-Entitlement")
        }
        return request
    }

    /// Read a response, refusing to buffer more than `maxResponseBytes`.
    ///
    /// `URLSession.data(for:)` would happily materialize whatever an
    /// operator sends. The bytes here are untrusted and their only soft
    /// bound is a figure the same operator published, so the cap is
    /// enforced on our side (§13).
    func perform(_ request: URLRequest, maxResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackupError.operatorUnavailable
        }
        var data = Data()
        data.reserveCapacity(min(maxResponseBytes, 1 << 20))
        for try await byte in stream {
            data.append(byte)
            if data.count > maxResponseBytes {
                throw BackupError.operatorUnavailable
            }
        }
        return (data, http)
    }

    /// Stream a body straight to disk, bounded by what the reference
    /// says it should be.
    func stream(path: [String], to destination: URL, maxBytes: Int) async throws {
        let url = path.reduce(endpoint) { $0.appending(path: $1) }
        let request = try await makeRequest(
            method: "GET", url: url, body: Data(), contentType: nil, signed: true
        )
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackupError.operatorUnavailable }
        guard (200..<300).contains(http.statusCode) else {
            // The body of a failed download is small; read it bounded so
            // the operator's own code and message survive.
            var body = Data()
            for try await byte in stream where body.count < 8 << 10 { body.append(byte) }
            try Self.check(http, body)
            return
        }

        FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        var total = 0
        for try await byte in stream {
            buffer.append(byte)
            total += 1
            if total > maxBytes {
                // More bytes than the reference claims. The digest check
                // would catch it later, after writing all of them to a
                // device that may not have the room.
                try? FileManager.default.removeItem(at: destination)
                throw BackupError.incompleteSnapshot
            }
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }

    /// Map a non-2xx onto the domain vocabulary of §14, keeping the
    /// per-code fields the profile pins.
    static func check(_ http: HTTPURLResponse, _ data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }

        struct Envelope: Decodable {
            let error: String
            let message: String?
            let currentTermsId: String?
            let maximumSealedSnapshotBytes: Int?
            let retainedSnapshots: Int?
            let maximumRetainedSnapshots: Int?
            let retainedBytes: Int?
            let limitBytes: Int?
            let paymentRequired: PaymentRequired?

            struct PaymentRequired: Decodable {
                let componentId: String
                let offers: [String]
                let entitlementIssuers: [String]
            }
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw BackupError.rejected(
                code: "http_\(http.statusCode)",
                message: "the operator rejected the request (HTTP \(http.statusCode))"
            )
        }

        switch envelope.error {
        case "terms_changed":
            throw BackupError.termsChanged(currentTermsId: envelope.currentTermsId)
        case "payment_required":
            guard let payment = envelope.paymentRequired else {
                throw BackupError.rejected(code: envelope.error, message: envelope.message)
            }
            throw BackupError.paymentRequired(
                componentId: payment.componentId,
                offerIds: payment.offers,
                entitlementIssuers: payment.entitlementIssuers
            )
        case "invalid_entitlement":
            throw BackupError.invalidEntitlement(entitlementIssuers: [])
        case "signature_invalid":
            throw BackupError.accessRefused
        case "snapshot_too_large":
            throw BackupError.snapshotTooLarge(
                maximumSealedSnapshotBytes: envelope.maximumSealedSnapshotBytes
            )
        case "quota_exceeded":
            throw BackupError.quotaExceeded(
                retainedSnapshots: envelope.retainedSnapshots,
                maximumRetainedSnapshots: envelope.maximumRetainedSnapshots,
                retainedBytes: envelope.retainedBytes,
                limitBytes: envelope.limitBytes
            )
        case "digest_mismatch", "chunk_mismatch":
            throw BackupError.incompleteSnapshot
        case "retention_expired":
            throw BackupError.retentionExpired
        case "export_withheld":
            // Non-conforming. Surfaced by name so the UI can say so
            // rather than softening it into a generic failure.
            throw BackupError.exportWithheld
        case "unsupported_profile":
            throw BackupError.unsupportedProfile
        case "invalid_reference":
            throw BackupError.invalidReference
        default:
            // An operator code we do not model is preserved verbatim
            // rather than flattened into a local guess.
            throw BackupError.rejected(code: envelope.error, message: envelope.message)
        }
    }

    func verifyTermsSignature(_ terms: BackupTerms) throws {
        guard
            let signature = terms.signature,
            let keyHex = manifest.operatorKey.split(separator: ":").last.map(String.init),
            let keyBytes = BackupFormat.data(fromLowercaseHex: keyHex),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else {
            // An unsigned or unverifiable terms document is not terms.
            // Enrolment stops here rather than pinning something nobody
            // can be held to.
            throw BackupError.termsUnavailable
        }
        let signingBytes = try ServiceManifestCanonical.signingBytes(
            of: terms.rawBytes,
            omitting: ["termsId", "signature"]
        )
        guard key.isValidSignature(signature, for: signingBytes) else {
            throw BackupError.termsUnavailable
        }
    }
}

/// One operator outcome as it arrives on the wire.
struct WireOutcome: Decodable {
    let componentId: String?
    let status: String
    let snapshotReference: SnapshotReference?
    let locator: String?
    let retainedUntil: Date?
    let termsId: String?

    func domain(operationId: String, componentId fallback: String) throws -> BackupOutcome {
        // An unrecognised status becomes `unknown`, never `retained`.
        // A future operator inventing a word must not be read as
        // success by a client that has never heard of it.
        let mapped = BackupOutcomeStatus(rawValue: status) ?? .unknown
        return BackupOutcome(
            operationId: operationId,
            componentId: componentId ?? fallback,
            status: mapped,
            snapshotReference: snapshotReference,
            locator: locator,
            retainedUntil: retainedUntil,
            termsId: termsId
        )
    }
}

/// Refuses every redirect.
///
/// A signed request follows a signature over one path at one origin. An
/// operator that could redirect it would be choosing where our
/// credentials go.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
