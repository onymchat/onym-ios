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
        // Through `BackupFormat`, not `.iso8601`, so every timestamp
        // the operator sends — `retainedAt` in a listing as much as a
        // receipt's `acknowledgedAt` — is read by the one reader whose
        // tolerance this module owns and tests. The operator's clock
        // stamps fractional seconds, and whether `.iso8601` accepts
        // those is a fact about the Foundation build, not about this
        // code; the rolling window must not hang on it.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = BackupFormat.date(fromRFC3339: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an RFC 3339 timestamp")
            }
            return date
        }
        return decoder
    }()

    /// Split a top-level JSON array into its elements' *own* byte
    /// ranges, verbatim.
    ///
    /// For a response whose elements are kept as evidence — erasure
    /// receipts — parsing and re-serializing would substitute this
    /// client's key order, whitespace, and number formatting for the
    /// operator's, and a signature over the original bytes could never
    /// be checked against the substitute. So the array structure is the
    /// only thing read here; each element's bytes pass through
    /// untouched, and whether they are a well-formed receipt is the
    /// element decoder's question.
    ///
    /// Returns `nil` when `data` is not a complete top-level array —
    /// truncated, trailing garbage, or not an array at all.
    static func topLevelJSONArrayElements(in data: Data) -> [Data]? {
        let space: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0d]
        var index = data.startIndex
        func skipWhitespace() {
            while index < data.endIndex, space.contains(data[index]) { index += 1 }
        }
        func element(endingAt end: Data.Index, from start: Data.Index) -> Data {
            var trimmed = end
            while trimmed > start, space.contains(data[data.index(before: trimmed)]) {
                trimmed = data.index(before: trimmed)
            }
            return data.subdata(in: start..<trimmed)
        }

        skipWhitespace()
        guard index < data.endIndex, data[index] == UInt8(ascii: "[") else { return nil }
        index += 1
        skipWhitespace()

        var elements: [Data] = []
        var closed = false
        if index < data.endIndex, data[index] == UInt8(ascii: "]") {
            index += 1
            closed = true
        }
        var depth = 0
        var inString = false
        var escaped = false
        var start = index
        while !closed, index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: #"\"#) { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "]") where depth == 0:
                    guard index > start || !elements.isEmpty else { return nil }
                    elements.append(element(endingAt: index, from: start))
                    index += 1
                    closed = true
                    continue
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth < 0 { return nil }
                case UInt8(ascii: ",") where depth == 0:
                    guard index > start else { return nil }
                    elements.append(element(endingAt: index, from: start))
                    index += 1
                    skipWhitespace()
                    start = index
                    continue
                default: break
                }
            }
            index += 1
        }
        guard closed else { return nil }
        skipWhitespace()
        guard index == data.endIndex else { return nil }
        return elements
    }

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
        // Accumulated into an array rather than appended to `Data` one
        // byte at a time: at a 32 MiB cap the per-append cost is the
        // dominant term, and this runs on someone's phone.
        var bytes = [UInt8]()
        bytes.reserveCapacity(min(maxResponseBytes, 1 << 20))
        for try await byte in stream {
            bytes.append(byte)
            if bytes.count > maxResponseBytes {
                throw BackupError.operatorUnavailable
            }
        }
        return (Data(bytes), http)
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
            // the operator's own code and message survive. `break`, not
            // a `where` clause — the latter stops appending but keeps
            // draining, so an unbounded error body would still be read
            // to completion.
            var body = [UInt8]()
            for try await byte in stream {
                if body.count >= 8 << 10 { break }
                body.append(byte)
            }
            try Self.check(http, Data(body))
            return
        }

        FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let handle = try FileHandle(forWritingTo: destination)

        // `destination` is caller-owned — a restore path, not the swept
        // working directory — so *any* exit that is not a complete file
        // takes the partial with it. A write error and a network drop
        // leave the same wreckage as an over-long body, and the same
        // argument applies: a restore is where a silently-short file
        // must not arrive.
        var complete = false
        defer {
            try? handle.close()
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }

        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 20)
        var total = 0
        for try await byte in stream {
            buffer.append(byte)
            total += 1
            if total > maxBytes {
                // More bytes than the reference claims. The digest check
                // would catch it later, after writing all of them to a
                // device that may not have the room.
                throw BackupError.incompleteSnapshot
            }
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: Data(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: Data(buffer)) }

        // Short is as wrong as long.
        guard total == maxBytes else { throw BackupError.incompleteSnapshot }
        complete = true
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
            let entitlementIssuers: [String]?
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
            // The issuers are the whole point of this refusal: without
            // them a caller cannot know which issuer to obtain a fresh
            // credential from.
            throw BackupError.invalidEntitlement(
                entitlementIssuers: envelope.entitlementIssuers
                    ?? envelope.paymentRequired?.entitlementIssuers
                    ?? []
            )
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

    /// Check the terms against the operator key the manifest pins.
    ///
    /// **Two signatures cover two different messages, and confusing them
    /// rejects an honest operator.** The document's own `signature`
    /// covers the canonical bytes with `termsId` and `signature`
    /// removed; the detached `.sig` served beside it covers the exact
    /// served bytes. This checked the detached one against the
    /// canonical message, which cannot verify for any correct operator
    /// — every enrolment failed with "terms could not be verified"
    /// while the operator was serving a perfectly valid document.
    ///
    /// Both are checked now, each against the bytes it actually signs.
    /// They are independent guarantees rather than a belt-and-braces
    /// pair: the embedded one is what a pinned `termsId` is a digest
    /// of, and the detached one is what proves the bytes on the wire
    /// were not altered in transit by something that could also
    /// recanonicalize them.
    func verifyTermsSignature(_ terms: BackupTerms) throws {
        guard
            let keyHex = manifest.operatorKey.split(separator: ":").last.map(String.init),
            let keyBytes = BackupFormat.data(fromLowercaseHex: keyHex),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
            let embedded = terms.embeddedSignature
        else {
            // An unsigned or unverifiable terms document is not terms.
            // Enrolment stops here rather than pinning something nobody
            // can be held to.
            throw BackupError.termsUnavailable
        }
        let canonical = try ServiceManifestCanonical.signingBytes(
            of: terms.rawBytes,
            omitting: ["termsId", "signature"]
        )
        guard key.isValidSignature(embedded, for: canonical) else {
            throw BackupError.termsUnavailable
        }
        // The `.sig` sibling is optional on the wire, but a served one
        // that does not verify is worse than an absent one: it is a
        // disagreement between two things the same operator published.
        if let detached = terms.detachedSignature {
            guard key.isValidSignature(detached, for: terms.rawBytes) else {
                throw BackupError.termsUnavailable
            }
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
