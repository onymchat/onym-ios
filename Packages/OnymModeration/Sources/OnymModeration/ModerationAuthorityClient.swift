import Foundation

/// Receipt returned after the Interface registers a countersigned
/// mandate with the Authority. The reference is the SHA-256 of the
/// mandate's canonical unsigned bytes and must agree with the value the
/// client computed before registration.
public struct MandateRegistrationReceipt: Codable, Sendable, Equatable {
    public let mandateRef: String
    public let accepted: Bool

    public init(mandateRef: String, accepted: Bool) {
        self.mandateRef = mandateRef
        self.accepted = accepted
    }
}

/// Receipt for a filed report, matching the merged Authority response.
/// `intakeWeight` and `duplicate` are optional because an exact replay
/// returns the original case and deadlines without recalculating weight.
public struct ReportReceipt: Codable, Sendable, Equatable {
    public let reportId: String
    public let receivedAt: Date
    public let caseId: String
    public let intakeWeight: Double?
    public let responseDeadline: Date?
    public let decisionDeadline: Date?
    public let duplicate: Bool?

    public init(
        reportId: String,
        receivedAt: Date,
        caseId: String,
        intakeWeight: Double? = nil,
        responseDeadline: Date? = nil,
        decisionDeadline: Date? = nil,
        duplicate: Bool? = nil
    ) {
        self.reportId = reportId
        self.receivedAt = receivedAt
        self.caseId = caseId
        self.intakeWeight = intakeWeight
        self.responseDeadline = responseDeadline
        self.decisionDeadline = decisionDeadline
        self.duplicate = duplicate
    }
}

/// Stable error vocabulary emitted by the reference Authority.
public enum AuthorityErrorCode: String, Codable, Sendable, Equatable {
    case badRequest = "bad_request"
    case signatureInvalid = "signature_invalid"
    case reporterUnconsented = "reporter_unconsented"
    case noJurisdiction = "no_jurisdiction"
    case authenticityUnverified = "authenticity_unverified"
    case classOutsideMandate = "class_outside_mandate"
    case windowClosed = "window_closed"
    case caseState = "case_state"
    case notFound = "not_found"
    case internalError = "internal_error"
}

/// A non-2xx response from an Authority. `rawCode` is retained even
/// when a newer Authority introduces a code this app does not know yet.
public struct AuthorityRejection: Error, Sendable, Equatable {
    public let statusCode: Int
    public let rawCode: String
    public let message: String

    public var code: AuthorityErrorCode? { AuthorityErrorCode(rawValue: rawCode) }

    public init(statusCode: Int, rawCode: String, message: String) {
        self.statusCode = statusCode
        self.rawCode = rawCode
        self.message = message
    }
}

/// Client-side failures before a conforming Authority response can be
/// handed to the caller. Network failures remain their original
/// `URLError`, so retry policy can distinguish them directly.
public enum AuthorityClientError: Error, Sendable, Equatable {
    case invalidResponse
    case malformedResponse(String)
    case rejected(AuthorityRejection)
    case mandateReferenceMismatch(expected: String, received: String)
}

/// The accused's signed response to a case notice: statements and
/// counter-evidence. Additional evidence within the window travels
/// through the same object.
public struct CaseResponse: Codable, Sendable, Equatable {
    /// The case being answered. It is carried in the signed body as well
    /// as the request path to prevent cross-case replay.
    public let caseId: String
    public let statement: String
    public let evidence: [EvidenceItem]
    public var signature: String

    public init(
        caseId: String,
        statement: String,
        evidence: [EvidenceItem] = [],
        signature: String = ""
    ) {
        self.caseId = caseId
        self.statement = statement
        self.evidence = evidence
        self.signature = signature
    }

    /// The bytes the accused signs: every field except `signature`.
    public func signingBytes() throws -> Data {
        struct Unsigned: Encodable {
            let caseId: String
            let statement: String
            let evidence: [EvidenceItem]
        }
        return try ModerationCanonicalEncoder.encode(
            Unsigned(caseId: caseId, statement: statement, evidence: evidence)
        )
    }
}

/// An appeal filed within the declared window, or an unauthenticated
/// new-holder claim handled by the Authority's dedicated remedy.
public struct AppealSubmission: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case appeal
        case newHolderClaim = "new-holder-claim"
    }

    public let caseId: String
    public let kind: Kind
    public let statement: String
    public var signature: String

    public init(caseId: String, kind: Kind, statement: String, signature: String = "") {
        self.caseId = caseId
        self.kind = kind
        self.statement = statement
        self.signature = signature
    }

    /// The bytes the accused signs: every field except `signature`.
    public func signingBytes() throws -> Data {
        struct Unsigned: Encodable {
            let caseId: String
            let kind: Kind
            let statement: String
        }
        return try ModerationCanonicalEncoder.encode(
            Unsigned(caseId: caseId, kind: kind, statement: statement)
        )
    }
}

/// Party-visible subset of the Authority's case status document.
/// Additional assessment and event fields are deliberately ignored by
/// this first client surface and can be modeled when their UI lands.
public struct CaseStatus: Codable, Sendable, Equatable {
    public let caseId: String
    public let stage: String
    public let classId: String?
    public let openedAt: Date?
    public let responseDeadline: Date?
    public let decisionDeadline: Date?
    public let responded: Bool?
    public let responsesOnFile: Int?
    public let disposition: String?
    public let appealDeadline: Date?
    public let appealState: String?
    public let newHolderState: String?
    public let claimRevision: Int?

    public init(
        caseId: String,
        stage: String,
        classId: String? = nil,
        openedAt: Date? = nil,
        responseDeadline: Date? = nil,
        decisionDeadline: Date? = nil,
        responded: Bool? = nil,
        responsesOnFile: Int? = nil,
        disposition: String? = nil,
        appealDeadline: Date? = nil,
        appealState: String? = nil,
        newHolderState: String? = nil,
        claimRevision: Int? = nil
    ) {
        self.caseId = caseId
        self.stage = stage
        self.classId = classId
        self.openedAt = openedAt
        self.responseDeadline = responseDeadline
        self.decisionDeadline = decisionDeadline
        self.responded = responded
        self.responsesOnFile = responsesOnFile
        self.disposition = disposition
        self.appealDeadline = appealDeadline
        self.appealState = appealState
        self.newHolderState = newHolderState
        self.claimRevision = claimRevision
    }
}

/// User-initiated operations exposed by one moderation Authority.
public protocol ModerationAuthorityClient: Sendable {
    func registerMandate(_ mandate: ModerationMandate) async throws -> MandateRegistrationReceipt
    func fileReport(_ report: Report) async throws -> ReportReceipt
    func respond(_ response: CaseResponse) async throws
    func appeal(_ submission: AppealSubmission) async throws
    func queryStatus(caseId: String) async throws -> CaseStatus
}

/// Resolves the client for a directory-selected Authority. Keeping this
/// as a seam lets tests and UI fixtures avoid network access while the
/// production factory derives a concrete client from the listing.
public protocol ModerationAuthorityClientFactory: Sendable {
    func client(for listing: AuthorityListing) -> any ModerationAuthorityClient
}

public struct URLSessionModerationAuthorityClientFactory: ModerationAuthorityClientFactory {
    private let session: URLSession
    private let signer: any ModerationSigner
    private let clock: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        signer: any ModerationSigner,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.signer = signer
        self.clock = clock
    }

    public func client(for listing: AuthorityListing) -> any ModerationAuthorityClient {
        URLSessionModerationAuthorityClient(
            baseURL: listing.resolvedAPIBaseURL,
            session: session,
            signer: signer,
            clock: clock
        )
    }
}

/// HTTP implementation of the operation surface in `onym-moderation`.
/// Request objects are encoded once per call with the same canonical
/// encoder used for their signatures.
public struct URLSessionModerationAuthorityClient: ModerationAuthorityClient {
    private let baseURL: URL
    private let session: URLSession
    private let signer: any ModerationSigner
    private let clock: @Sendable () -> Date

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        signer: any ModerationSigner,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        self.session = session
        self.signer = signer
        self.clock = clock
    }

    public func registerMandate(
        _ mandate: ModerationMandate
    ) async throws -> MandateRegistrationReceipt {
        let body = try ModerationCanonicalEncoder.encode(mandate)
        let data = try await send(method: "POST", path: ["v1", "mandates"], body: body)
        let receipt: MandateRegistrationReceipt = try decode(data)
        let expected = try mandate.mandateHash()
        guard receipt.accepted, receipt.mandateRef == expected else {
            throw AuthorityClientError.mandateReferenceMismatch(
                expected: expected,
                received: receipt.mandateRef
            )
        }
        return receipt
    }

    public func fileReport(_ report: Report) async throws -> ReportReceipt {
        let body = try ModerationCanonicalEncoder.encode(report)
        let data = try await send(method: "POST", path: ["v1", "reports"], body: body)
        return try decode(data)
    }

    public func respond(_ response: CaseResponse) async throws {
        let body = try ModerationCanonicalEncoder.encode(response)
        _ = try await send(
            method: "POST",
            path: ["v1", "cases", response.caseId, "respond"],
            body: body
        )
    }

    public func appeal(_ submission: AppealSubmission) async throws {
        let body = try ModerationCanonicalEncoder.encode(submission)
        _ = try await send(
            method: "POST",
            path: ["v1", "cases", submission.caseId, "appeal"],
            body: body
        )
    }

    public func queryStatus(caseId: String) async throws -> CaseStatus {
        let timestamp = Self.timestamp(clock())
        let signedBytes = Data("query-status:\(caseId):\(timestamp)".utf8)
        let key = try await signer.userKeyID()
        let signature = try await signer.sign(signedBytes).base64EncodedString()
        let headers = [
            "X-Onym-Key": key,
            "X-Onym-Timestamp": timestamp,
            "X-Onym-Signature": signature,
        ]
        let data = try await send(
            method: "GET",
            path: ["v1", "cases", caseId, "status"],
            headers: headers
        )
        return try decode(data)
    }

    private func send(
        method: String,
        path: [String],
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        let url = path.reduce(baseURL) { partial, component in
            partial.appending(path: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthorityClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable {
                let error: String
                let message: String
            }
            let decoded = try? Self.decoder().decode(ErrorBody.self, from: data)
            throw AuthorityClientError.rejected(
                AuthorityRejection(
                    statusCode: http.statusCode,
                    rawCode: decoded?.error ?? "http_\(http.statusCode)",
                    message: decoded?.message ?? "Authority returned HTTP \(http.statusCode)"
                )
            )
        }
        return data
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try Self.decoder().decode(Value.self, from: data)
        } catch {
            throw AuthorityClientError.malformedResponse(String(describing: error))
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

/// Explicitly non-operational client for previews and scenarios that do
/// not configure an Authority service.
public struct StubModerationAuthorityClient: ModerationAuthorityClient {
    public init() {}

    public func registerMandate(
        _ mandate: ModerationMandate
    ) async throws -> MandateRegistrationReceipt {
        throw ModerationError.notImplemented("accept-mandate")
    }

    public func fileReport(_ report: Report) async throws -> ReportReceipt {
        throw ModerationError.notImplemented("file-report")
    }

    public func respond(_ response: CaseResponse) async throws {
        throw ModerationError.notImplemented("respond")
    }

    public func appeal(_ submission: AppealSubmission) async throws {
        throw ModerationError.notImplemented("appeal")
    }

    public func queryStatus(caseId: String) async throws -> CaseStatus {
        throw ModerationError.notImplemented("query-status")
    }
}

public struct StubModerationAuthorityClientFactory: ModerationAuthorityClientFactory {
    public init() {}

    public func client(for listing: AuthorityListing) -> any ModerationAuthorityClient {
        StubModerationAuthorityClient()
    }
}
