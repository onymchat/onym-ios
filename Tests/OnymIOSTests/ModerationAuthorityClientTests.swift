import XCTest
@testable import OnymModeration

final class ModerationAuthorityClientTests: XCTestCase {
    private let baseURL = URL(string: "https://authority.example/service")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var session: URLSession!

    private struct FakeSigner: ModerationSigner {
        func userKeyID() async throws -> String { "onym:key:0102" }
        func sign(_ message: Data) async throws -> Data {
            XCTAssertEqual(
                String(decoding: message, as: UTF8.self),
                "query-status:case-1:2023-11-14T22:13:20Z"
            )
            return Data("status-signature".utf8)
        }
    }

    private final class RecordedBodies: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func set(_ data: Data?, for key: String) {
            lock.withLock { values[key] = data }
        }

        func snapshot() -> [String: Data] {
            lock.withLock { values }
        }
    }

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func makeClient() -> URLSessionModerationAuthorityClient {
        URLSessionModerationAuthorityClient(
            baseURL: baseURL,
            session: session,
            signer: FakeSigner(),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func mandate() -> ModerationMandate {
        ModerationMandate(
            user: "onym:key:0102",
            interface: "onym:component:onym-ios",
            authority: "onym:component:authority",
            manifestHash: String(repeating: "a", count: 64),
            classes: ["csam"],
            deviceBinding: "device-1",
            acceptedAt: now,
            signatures: ["user-signature", "interface-signature"]
        )
    }

    func testAuthorityListingUsesExplicitAPIBaseURL() throws {
        let data = Data(#"""
        {
          "componentId":"onym:component:authority",
          "name":"Authority",
          "manifestURL":"https://cdn.example/authority/manifest.json",
          "apiBaseURL":"https://api.example/moderation",
          "operatorPublicKeyBase64":"key"
        }
        """#.utf8)
        let listing = try JSONDecoder().decode(AuthorityListing.self, from: data)

        XCTAssertEqual(listing.resolvedAPIBaseURL.absoluteString, "https://api.example/moderation")
    }

    func testLegacyAuthorityListingResolvesAPIBesideManifest() throws {
        let data = Data(#"""
        {
          "componentId":"onym:component:authority",
          "name":"Authority",
          "manifestURL":"https://authority.example/service/manifest.json",
          "operatorPublicKeyBase64":"key"
        }
        """#.utf8)
        let listing = try JSONDecoder().decode(AuthorityListing.self, from: data)

        XCTAssertNil(listing.apiBaseURL)
        XCTAssertEqual(listing.resolvedAPIBaseURL.absoluteString, "https://authority.example/service/")
    }

    func testRegisterMandatePostsCanonicalBodyAndChecksReference() async throws {
        let mandate = mandate()
        let expectedRef = try mandate.mandateHash()
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.absoluteString, "https://authority.example/service/v1/mandates")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try XCTUnwrap(Self.body(of: request))
            XCTAssertEqual(body, try JSONEncoder.moderationFixture().encode(mandate))
            let response = Data(#"{"accepted":true,"mandateRef":"\#(expectedRef)"}"#.utf8)
            return (response, Self.httpResponse(for: request, status: 200))
        }

        let receipt = try await makeClient().registerMandate(mandate)
        XCTAssertEqual(receipt, MandateRegistrationReceipt(mandateRef: expectedRef, accepted: true))
    }

    func testRegisterMandateReportsExplicitRejectionSeparatelyFromReferenceMismatch() async throws {
        let mandate = mandate()
        let expectedRef = try mandate.mandateHash()
        StubURLProtocol.set { request in
            let response = Data(#"{"accepted":false,"mandateRef":"\#(expectedRef)"}"#.utf8)
            return (response, Self.httpResponse(for: request, status: 200))
        }

        do {
            _ = try await makeClient().registerMandate(mandate)
            XCTFail("expected the Authority not to accept the mandate")
        } catch let AuthorityClientError.mandateNotAccepted(mandateRef) {
            XCTAssertEqual(mandateRef, expectedRef)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFileReportDecodesFullReferenceReceipt() async throws {
        let report = Report(
            reportId: "report-1",
            reporter: "onym:key:0102",
            reporterMandate: "mandate-1",
            accused: "onym:key:0304",
            classId: "csam",
            evidence: [EvidenceItem(disclosedContent: "content", authenticityProof: "proof")],
            filedAt: now,
            signature: "report-signature"
        )
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.absoluteString, "https://authority.example/service/v1/reports")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(Self.body(of: request), try JSONEncoder.moderationFixture().encode(report))
            let response = Data(#"""
            {
              "reportId":"report-1",
              "receivedAt":"2023-11-14T22:13:20Z",
              "caseId":"case-1",
              "intakeWeight":1.5,
              "responseDeadline":"2023-11-17T22:13:20Z",
              "decisionDeadline":"2023-11-21T22:13:20Z"
            }
            """#.utf8)
            return (response, Self.httpResponse(for: request, status: 200))
        }

        let receipt = try await makeClient().fileReport(report)
        XCTAssertEqual(receipt.reportId, "report-1")
        XCTAssertEqual(receipt.caseId, "case-1")
        XCTAssertEqual(receipt.intakeWeight, 1.5)
        XCTAssertNil(receipt.duplicate)
        XCTAssertNotNil(receipt.responseDeadline)
        XCTAssertNotNil(receipt.decisionDeadline)
    }

    func testAuthorityErrorVocabularyIsPreserved() async throws {
        StubURLProtocol.set { request in
            let body = Data(#"{"error":"no_jurisdiction","message":"no_jurisdiction"}"#.utf8)
            return (body, Self.httpResponse(for: request, status: 403))
        }

        do {
            _ = try await makeClient().fileReport(
                Report(
                    reportId: "report-1",
                    reporter: "onym:key:0102",
                    reporterMandate: "mandate-1",
                    accused: "onym:key:0304",
                    classId: "csam",
                    evidence: [],
                    filedAt: now,
                    signature: "signature"
                )
            )
            XCTFail("expected Authority refusal")
        } catch let AuthorityClientError.rejected(rejection) {
            XCTAssertEqual(rejection.statusCode, 403)
            XCTAssertEqual(rejection.code, .noJurisdiction)
            XCTAssertEqual(rejection.rawCode, "no_jurisdiction")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonJSONProxyErrorUsesHTTPStatusFallback() async throws {
        StubURLProtocol.set { request in
            (Data("bad gateway".utf8), Self.httpResponse(for: request, status: 502))
        }

        do {
            _ = try await makeClient().fileReport(
                Report(
                    reportId: "report-1",
                    reporter: "onym:key:0102",
                    reporterMandate: "mandate-1",
                    accused: "onym:key:0304",
                    classId: "csam",
                    evidence: [],
                    filedAt: now,
                    signature: "signature"
                )
            )
            XCTFail("expected proxy rejection")
        } catch let AuthorityClientError.rejected(rejection) {
            XCTAssertEqual(rejection.statusCode, 502)
            XCTAssertEqual(rejection.rawCode, "http_502")
            XCTAssertEqual(rejection.message, "Authority returned HTTP 502")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonHTTPResponseIsRejected() async throws {
        StubURLProtocol.set { request in
            let response = URLResponse(
                url: request.url!,
                mimeType: "application/json",
                expectedContentLength: 2,
                textEncodingName: nil
            )
            return (Data("{}".utf8), response)
        }

        do {
            _ = try await makeClient().registerMandate(mandate())
            XCTFail("expected a non-HTTP response to be rejected")
        } catch AuthorityClientError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMalformedSuccessBodyIsRejected() async throws {
        StubURLProtocol.set { request in
            (Data("{}".utf8), Self.httpResponse(for: request, status: 200))
        }

        do {
            _ = try await makeClient().registerMandate(mandate())
            XCTFail("expected malformed success response")
        } catch AuthorityClientError.malformedResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDuplicateReportReceiptDecodesReplayFields() async throws {
        StubURLProtocol.set { request in
            let response = Data(#"""
            {
              "reportId":"report-1",
              "receivedAt":"2023-11-14T22:13:20Z",
              "caseId":"case-1",
              "duplicate":true,
              "responseDeadline":"2023-11-17T22:13:20Z",
              "decisionDeadline":"2023-11-21T22:13:20Z"
            }
            """#.utf8)
            return (response, Self.httpResponse(for: request, status: 200))
        }

        let receipt = try await makeClient().fileReport(
            Report(
                reportId: "report-1",
                reporter: "onym:key:0102",
                reporterMandate: "mandate-1",
                accused: "onym:key:0304",
                classId: "csam",
                evidence: [],
                filedAt: now,
                signature: "signature"
            )
        )

        XCTAssertEqual(receipt.duplicate, true)
        XCTAssertNil(receipt.intakeWeight)
        XCTAssertEqual(receipt.caseId, "case-1")
    }

    func testStatusQueryUsesSignedHeaders() async throws {
        StubURLProtocol.set { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://authority.example/service/v1/cases/case-1/status"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Onym-Key"), "onym:key:0102")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Onym-Timestamp"),
                "2023-11-14T22:13:20Z"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Onym-Signature"),
                Data("status-signature".utf8).base64EncodedString()
            )
            let response = Data(#"""
            {
              "caseId":"case-1",
              "stage":"open",
              "classId":"csam",
              "openedAt":"2023-11-14T22:13:20Z",
              "responseDeadline":"2023-11-17T22:13:20Z",
              "decisionDeadline":"2023-11-21T22:13:20Z",
              "responded":false,
              "responsesOnFile":0,
              "appealState":"none",
              "newHolderState":"none",
              "claimRevision":0,
              "assessment":null,
              "events":[]
            }
            """#.utf8)
            return (response, Self.httpResponse(for: request, status: 200))
        }

        let status = try await makeClient().queryStatus(caseId: "case-1")
        XCTAssertEqual(status.caseId, "case-1")
        XCTAssertEqual(status.stage, "open")
        XCTAssertEqual(status.classId, "csam")
        XCTAssertEqual(status.responded, false)
    }

    func testResponseAndAppealPutCaseIDInPathAndSignedBody() async throws {
        let recorded = RecordedBodies()
        StubURLProtocol.set { request in
            recorded.set(Self.body(of: request), for: request.url!.lastPathComponent)
            return (
                Data(#"{"recorded":true}"#.utf8),
                Self.httpResponse(for: request, status: 200)
            )
        }
        let client = makeClient()
        let response = CaseResponse(caseId: "case-1", statement: "answer", signature: "sig")
        let appeal = AppealSubmission(
            caseId: "case-1",
            kind: .appeal,
            statement: "review",
            signature: "sig"
        )

        try await client.respond(response)
        try await client.appeal(appeal)

        let bodies = recorded.snapshot()
        XCTAssertEqual(bodies["respond"], try JSONEncoder.moderationFixture().encode(response))
        XCTAssertEqual(bodies["appeal"], try JSONEncoder.moderationFixture().encode(appeal))
    }

    private static func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// URLSession presents an `httpBody` as a stream to custom
    /// URLProtocols even when the caller assigned `Data` directly.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

private extension JSONEncoder {
    static func moderationFixture() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
