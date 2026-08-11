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
    case mandateNotAccepted(mandateRef: String)
    case mandateReferenceMismatch(expected: String, received: String)
    case reportIdentifierMismatch(expected: String, received: String)
    case caseIdentifierMismatch(expected: String, received: String)
    case invalidPathComponent(String)
    case insecureBaseURL(String)
}

/// The accused's signed response to a case notice: statements and
/// counter-evidence (Moderation.md §5.5 — "the response mirrors the
/// report's shape"). Additional evidence within the window travels
/// through the same object, so `submit-evidence` needs no separate
/// operation client-side.
public struct CaseResponse: Codable, Sendable, Equatable {
    /// The case being answered. Carried in the object — and therefore
    /// inside the signed bytes — rather than alongside it: a signed
    /// statement that names no case can be lifted from the case it was
    /// written for and replayed onto another, so an innocuous "that
    /// wasn't me" would register as an answer to an accusation its
    /// signer never saw.
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
    /// See `ModerationCanonicalEncoder` for why the ordering matters.
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

/// An appeal filed within the declared window — or a new-holder claim,
/// which the spec treats as a mandatory appeal class with expedited
/// review (§5.7; the spec's error identifier is `new_holder_claim`,
/// but the reference wire value for `kind` — request and echoed
/// receipt alike — is the hyphenated `new-holder-claim`, and the
/// reference echoes the submitted string verbatim).
public struct AppealSubmission: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case appeal
        case newHolderClaim = "new-holder-claim"
    }

    /// The case appealed. Signed, for the same replay reason as
    /// `CaseResponse.caseId`.
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
    ///
    /// A `newHolderClaim` is signed too where the holder still has the
    /// mandated identity, but an authority cannot require it — the
    /// whole premise of that path is a device whose new owner is *not*
    /// the mandated user (§5.7).
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

/// The Authority's acknowledgment of a filed case response
/// (`POST /v1/cases/{id}/respond`). The reference enforces no response
/// deadline — a late filing is accepted and flagged, never refused —
/// so `late` is information for the user, not an error.
public struct CaseResponseReceipt: Codable, Sendable, Equatable {
    public let caseId: String
    public let recorded: Bool
    public let late: Bool

    public init(caseId: String, recorded: Bool, late: Bool) {
        self.caseId = caseId
        self.recorded = recorded
        self.late = late
    }
}

/// The Authority's acknowledgment of an appeal or new-holder filing.
/// For a new-holder claim the reference answers 200 with `filed: true`
/// unconditionally — deliberately non-oracular — so `filed` never
/// proves the claim was recorded; only the authenticated status
/// endpoint's `newHolderState` can show that.
public struct AppealReceipt: Codable, Sendable, Equatable {
    public let caseId: String
    public let filed: Bool
    public let kind: String
    public let note: String?

    public init(caseId: String, filed: Bool, kind: String, note: String? = nil) {
        self.caseId = caseId
        self.filed = filed
        self.kind = kind
        self.note = note
    }
}

/// One entry of the Authority's case event log. The reference exposes
/// timestamps and kinds only ("case_opened", "response", "decided",
/// "appeal_filed", ...) — details are never served to a party.
public struct CaseEvent: Codable, Sendable, Equatable {
    public let at: Date
    public let kind: String

    public init(at: Date, kind: String) {
        self.at = at
        self.kind = kind
    }
}

/// Party-visible subset of the Authority's case status document.
/// The `assessment` field is deliberately ignored by this client
/// surface and can be modeled when its UI lands.
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
    /// Oldest-first event log. Optional for compatibility with an
    /// authority that omits it; the reference always serves it.
    public let events: [CaseEvent]?

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
        claimRevision: Int? = nil,
        events: [CaseEvent]? = nil
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
        self.events = events
    }
}

/// The client-visible operations of a moderation Authority. Notices
/// and verdicts travel the other way via the Interface's gate check.
/// `submit-evidence` is folded into `respond` because it has the same
/// signed shape and window.
///
/// HTTP implementations put `CaseResponse.caseId` and
/// `AppealSubmission.caseId` in both the path and signed body. A
/// conforming Authority must reject a path/body mismatch; trusting
/// either value alone would reopen cross-case replay.
public protocol ModerationAuthorityClient: Sendable {
    func registerMandate(_ mandate: ModerationMandate) async throws -> MandateRegistrationReceipt
    func fileReport(_ report: Report) async throws -> ReportReceipt

    /// Upload the bytes of one reported image, addressed by their
    /// SHA-256.
    ///
    /// Evidence bytes travel on their own content-addressed route
    /// rather than inside the report: they do not fit in the JSON body
    /// limit, and naming them by digest is what makes the upload safe
    /// to accept at all. The Authority recomputes the hash and matches
    /// it against the digest the accused signed, so bytes that hash to
    /// anything else are simply not the reported photo.
    ///
    /// Idempotent by construction — re-uploading the same bytes is the
    /// same object, so an interrupted upload resumes by sending them
    /// again.
    func uploadEvidenceImage(sha256: String, bytes: Data) async throws
    @discardableResult
    func respond(_ response: CaseResponse) async throws -> CaseResponseReceipt
    @discardableResult
    func appeal(_ submission: AppealSubmission) async throws -> AppealReceipt
    func queryStatus(caseId: String) async throws -> CaseStatus
    func queryRecoverableCases() async throws -> [String]

    /// File a device-recovery claim (§6): a real contact for the
    /// moderator to verify the holder through, and the holder's own
    /// account of how they hold the marked device. Requirements (not
    /// extension-only) so `any ModerationAuthorityClient` dispatches
    /// to the real client; refusing defaults keep other conformers
    /// source-compatible.
    func fileRecoveryClaim(contact: String, statement: String) async throws -> String
    func recoveryClaimStatus(claimId: String) async throws -> RecoveryClaimStatus
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
            baseURL: listing.apiBaseURL,
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
        guard receipt.mandateRef == expected else {
            throw AuthorityClientError.mandateReferenceMismatch(
                expected: expected,
                received: receipt.mandateRef
            )
        }
        guard receipt.accepted else {
            throw AuthorityClientError.mandateNotAccepted(mandateRef: receipt.mandateRef)
        }
        return receipt
    }

    public func fileReport(_ report: Report) async throws -> ReportReceipt {
        let body = try ModerationCanonicalEncoder.encode(report)
        let data = try await send(method: "POST", path: ["v1", "reports"], body: body)
        let receipt: ReportReceipt = try decode(data)
        guard receipt.reportId == report.reportId else {
            throw AuthorityClientError.reportIdentifierMismatch(
                expected: report.reportId,
                received: receipt.reportId
            )
        }
        return receipt
    }

    public func uploadEvidenceImage(sha256: String, bytes: Data) async throws {
        let timestamp = Self.timestamp(clock())
        // The exact credential message the reference Authority verifies
        // (`authority/src/api.rs`, `put_evidence_blob`). It authorizes
        // the upload — it is not what makes the bytes trustworthy; the
        // digest in the path does that.
        let signedBytes = Data("evidence-blob:\(sha256):\(timestamp)".utf8)
        let key = try await signer.userKeyID()
        let signature = try await signer.sign(signedBytes).base64EncodedString()
        _ = try await send(
            method: "PUT",
            path: ["v1", "evidence-blobs", sha256],
            body: bytes,
            // Opaque bytes, not JSON. The Authority sniffs the real type
            // from the content and ignores whatever is declared here,
            // but sending `application/json` would still be a lie.
            contentType: "application/octet-stream",
            headers: [
                "X-Onym-Key": key,
                "X-Onym-Timestamp": timestamp,
                "X-Onym-Signature": signature,
            ]
        )
    }

    @discardableResult
    public func respond(_ response: CaseResponse) async throws -> CaseResponseReceipt {
        let body = try ModerationCanonicalEncoder.encode(response)
        let data = try await send(
            method: "POST",
            path: ["v1", "cases", response.caseId, "respond"],
            body: body
        )
        let receipt: CaseResponseReceipt = try decode(data)
        guard receipt.caseId == response.caseId else {
            throw AuthorityClientError.caseIdentifierMismatch(
                expected: response.caseId,
                received: receipt.caseId
            )
        }
        return receipt
    }

    @discardableResult
    public func appeal(_ submission: AppealSubmission) async throws -> AppealReceipt {
        let body = try ModerationCanonicalEncoder.encode(submission)
        let data = try await send(
            method: "POST",
            path: ["v1", "cases", submission.caseId, "appeal"],
            body: body
        )
        let receipt: AppealReceipt = try decode(data)
        guard receipt.caseId == submission.caseId else {
            throw AuthorityClientError.caseIdentifierMismatch(
                expected: submission.caseId,
                received: receipt.caseId
            )
        }
        // The reference echoes the filed kind; an acknowledgment for a
        // different kind must not be attributed to this submission.
        guard receipt.kind == submission.kind.rawValue else {
            throw AuthorityClientError.malformedResponse(
                "appeal receipt kind '\(receipt.kind)' does not match submitted '\(submission.kind.rawValue)'"
            )
        }
        return receipt
    }

    public func queryStatus(caseId: String) async throws -> CaseStatus {
        let timestamp = Self.timestamp(clock())
        // This is deliberately the exact credential message verified by
        // the merged reference Authority (`authority/src/api.rs`,
        // `authorize_case_party`). Changing it client-side to include a
        // request line or host would make status queries incompatible.
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
        let status: CaseStatus = try decode(data)
        // A status document for a different case must never be
        // attributed to the one the caller asked about.
        guard status.caseId == caseId else {
            throw AuthorityClientError.caseIdentifierMismatch(
                expected: caseId,
                received: status.caseId
            )
        }
        return status
    }

    public func queryRecoverableCases() async throws -> [String] {
        let timestamp = Self.timestamp(clock())
        let key = try await signer.userKeyID()
        let signature = try await signer.sign(Data("list-cases:\(timestamp)".utf8)).base64EncodedString()
        let headers = [
            "X-Onym-Key": key,
            "X-Onym-Timestamp": timestamp,
            "X-Onym-Signature": signature,
        ]
        return try await decode(
            try await send(method: "GET", path: ["v1", "cases", "mine"], headers: headers)
        )
    }

    /// File a device-recovery claim (§6). Signed by the *new* identity
    /// key — the grantee a moderator's grant would name; the old key
    /// is exactly what was lost. Filing moves nothing anywhere: a
    /// human decides the claim.
    public func fileRecoveryClaim(contact: String, statement: String) async throws -> String {
        struct Unsigned: Encodable {
            let contact, grantee, statement, timestamp: String
        }
        struct Signed: Encodable {
            let contact, grantee, signature, statement, timestamp: String
        }
        struct Receipt: Decodable {
            let claimId: String
        }
        let timestamp = Self.timestamp(clock())
        let grantee = try await signer.userKeyID()
        // The authority verifies over the canonical bytes with the
        // signature field removed — the same form `Unsigned` encodes,
        // as long as `Signed` adds nothing but the signature. This is
        // deliberately the exact field set the reference Authority's
        // `file_recovery_claim` (`authority/src/api.rs`,
        // onym-moderation#28) recomputes via
        // `canonical::grant_signing_bytes(&body)`: the request body
        // minus `signature`, keys sorted. Adding a field client-side
        // without the authority knowing it would not break the
        // signature (it verifies the body it received) — but renaming
        // or dropping one of these four would.
        let signingBytes = try ModerationCanonicalEncoder.encode(
            Unsigned(contact: contact, grantee: grantee, statement: statement, timestamp: timestamp)
        )
        let signature = try await signer.sign(signingBytes).base64EncodedString()
        let body = try ModerationCanonicalEncoder.encode(
            Signed(
                contact: contact,
                grantee: grantee,
                signature: signature,
                statement: statement,
                timestamp: timestamp
            )
        )
        let receipt: Receipt = try await decode(
            try await send(method: "POST", path: ["v1", "recovery-claims"], body: body)
        )
        return receipt.claimId
    }

    /// Where a filed claim stands. Answered only to the key the claim
    /// names; when granted, the response carries the grant's exact
    /// signed bytes.
    public func recoveryClaimStatus(claimId: String) async throws -> RecoveryClaimStatus {
        struct Wire: Decodable {
            let state: String
            let reasoning: String?
            let grant: Data?
        }
        let timestamp = Self.timestamp(clock())
        let key = try await signer.userKeyID()
        // This is deliberately the exact credential message verified by
        // the reference Authority (`authority/src/api.rs`,
        // `recovery_claim_status`, onym-moderation#28) — as with
        // `query-status:` above, changing it client-side would make
        // every status poll answer 404. The response's `{state,
        // reasoning, grant}` (grant base64) is that handler's shape too.
        let message = Data("recovery-claim-status:\(claimId):\(timestamp)".utf8)
        let signature = try await signer.sign(message).base64EncodedString()
        let wire: Wire = try await decode(
            try await send(
                method: "GET",
                path: ["v1", "recovery-claims", claimId],
                headers: [
                    "X-Onym-Key": key,
                    "X-Onym-Timestamp": timestamp,
                    "X-Onym-Signature": signature,
                ]
            )
        )
        return RecoveryClaimStatus(
            state: wire.state,
            reasoning: wire.reasoning,
            grant: try wire.grant.map { try RecoveryGrant(raw: $0) }
        )
    }

    private func send(
        method: String,
        path: [String],
        body: Data? = nil,
        contentType: String = "application/json",
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw AuthorityClientError.insecureBaseURL(baseURL.absoluteString)
        }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let invalid = path.first(where: {
            $0 == "." || $0 == ".." || $0.rangeOfCharacter(from: allowed.inverted) != nil
        }) else {
            return try await sendValidated(
                method: method,
                path: path,
                body: body,
                contentType: contentType,
                headers: headers
            )
        }
        throw AuthorityClientError.invalidPathComponent(invalid)
    }

    private func sendValidated(
        method: String,
        path: [String],
        body: Data?,
        contentType: String,
        headers: [String: String]
    ) async throws -> Data {
        let url = path.reduce(baseURL) { partial, component in
            partial.appending(path: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = body
        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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
        ModerationJSON.decoder()
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

    public func uploadEvidenceImage(sha256: String, bytes: Data) async throws {
        throw ModerationError.notImplemented("upload-evidence-image")
    }

    public func respond(_ response: CaseResponse) async throws -> CaseResponseReceipt {
        throw ModerationError.notImplemented("respond")
    }

    public func appeal(_ submission: AppealSubmission) async throws -> AppealReceipt {
        throw ModerationError.notImplemented("appeal")
    }

    public func queryStatus(caseId: String) async throws -> CaseStatus {
        throw ModerationError.notImplemented("query-status")
    }

    public func queryRecoverableCases() async throws -> [String] {
        throw ModerationError.notImplemented("list-cases")
    }
}

public struct StubModerationAuthorityClientFactory: ModerationAuthorityClientFactory {
    public init() {}

    public func client(for listing: AuthorityListing) -> any ModerationAuthorityClient {
        StubModerationAuthorityClient()
    }
}
