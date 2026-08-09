import XCTest
@testable import OnymModeration

/// Wire tests for `URLSessionEnforcementBackendClient` against the
/// reference apple service's shapes. The riskiest assumption — that
/// the server emits `GateCheckResult` in Swift's synthesized-enum JSON
/// (`{"caseOpen":{"_0":[…]}}`, `{"clear":{}}`) — is pinned here for
/// all four cases, along with the request body shapes (camelCase,
/// base64 `Data`, RFC 3339 timestamps) and the `{error, message}`
/// envelope.
final class EnforcementBackendClientTests: XCTestCase {
    private let baseURL = URL(string: "https://moderation.example")!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func makeClient() -> URLSessionEnforcementBackendClient {
        URLSessionEnforcementBackendClient(baseURL: baseURL, session: session)
    }

    private final class RecordedRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var _body: Data?
        private var _url: URL?

        func record(url: URL?, body: Data?) {
            lock.withLock {
                _url = url
                _body = body
            }
        }

        var body: Data? { lock.withLock { _body } }
        var url: URL? { lock.withLock { _url } }
    }

    /// URLSession presents an assigned `httpBody` to URLProtocols as a
    /// stream.
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
            body.append(buffer, count: count)
        }
        return body
    }

    private static func ok(_ request: URLRequest, _ json: String) -> (Data, URLResponse) {
        (
            Data(json.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    // MARK: - Enroll

    func testEnrollSendsCamelCaseBase64BodyAndDecodesBinding() async throws {
        let recorded = RecordedRequest()
        StubURLProtocol.set { request in
            recorded.record(url: request.url, body: Self.body(of: request))
            return Self.ok(request, #"{"deviceBinding":"binding-1"}"#)
        }

        let enrollment = try await makeClient().enrollDevice(EnrollmentRequest(
            deviceToken: Data([0x01, 0x02]),
            userKey: "onym:key:0102",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            signature: Data("sig".utf8)
        ))

        XCTAssertEqual(enrollment, DeviceEnrollment(deviceBinding: "binding-1"))
        XCTAssertEqual(recorded.url?.path(), "/v1/enroll")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(recorded.body)) as? [String: Any]
        )
        // camelCase keys, base64 Data, RFC 3339 seconds — the exact
        // shapes the reference apple service parses.
        XCTAssertEqual(json["deviceToken"] as? String, Data([0x01, 0x02]).base64EncodedString())
        XCTAssertEqual(json["userKey"] as? String, "onym:key:0102")
        XCTAssertEqual(json["timestamp"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(json["signature"] as? String, Data("sig".utf8).base64EncodedString())
    }

    func testEnrollWithNilTokenOmitsTheKeyEntirely() async throws {
        // The apple service's serde `Option<String>` treats an absent
        // key as None; the signed payload hashes a nil token as empty.
        // The simulator / no-attestation path ships exactly this shape.
        let recorded = RecordedRequest()
        StubURLProtocol.set { request in
            recorded.record(url: request.url, body: Self.body(of: request))
            return Self.ok(request, #"{"deviceBinding":"binding-1"}"#)
        }

        _ = try await makeClient().enrollDevice(EnrollmentRequest(
            deviceToken: nil,
            userKey: "onym:key:0102",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            signature: Data("sig".utf8)
        ))

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(recorded.body)) as? [String: Any]
        )
        XCTAssertNil(json["deviceToken"], "nil token must be an absent key, not null")
        XCTAssertFalse(json.keys.contains("deviceToken"))
    }

    func testGateCheckWithNilTokenAndMandateRefOmitsBothKeys() async throws {
        let recorded = RecordedRequest()
        StubURLProtocol.set { request in
            recorded.record(url: request.url, body: Self.body(of: request))
            return Self.ok(request, #"{"clear":{}}"#)
        }

        _ = try await makeClient().gateCheck(GateCheckRequest(
            deviceToken: nil,
            userKey: "onym:key:0102",
            mandateRef: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            signature: Data("sig".utf8)
        ))

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(recorded.body)) as? [String: Any]
        )
        XCTAssertFalse(json.keys.contains("deviceToken"))
        XCTAssertFalse(json.keys.contains("mandateRef"))
        XCTAssertEqual(json["userKey"] as? String, "onym:key:0102")
    }

    // MARK: - Countersign

    func testCountersignSendsCanonicalMandateAndDecodesSignature() async throws {
        let recorded = RecordedRequest()
        StubURLProtocol.set { request in
            recorded.record(url: request.url, body: Self.body(of: request))
            return Self.ok(request, #"{"signature":"aW50ZXJmYWNl"}"#)
        }
        let mandate = ModerationMandate(
            user: "onym:key:0102",
            interface: "onym:component:onym-ios",
            authority: "onym:component:authority",
            manifestHash: String(repeating: "a", count: 64),
            classes: ["csam"],
            deviceBinding: "binding-1",
            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            signatures: ["user-signature"]
        )

        let countersignature = try await makeClient().countersignMandate(mandate)

        XCTAssertEqual(countersignature.signature, "aW50ZXJmYWNl")
        XCTAssertEqual(recorded.url?.path(), "/v1/mandates/countersign")
        // The transmitted body is the canonical encoding — the server
        // recomputes signing bytes from these exact bytes.
        XCTAssertEqual(recorded.body, try ModerationCanonicalEncoder.encode(mandate))
    }

    // MARK: - Gate check result shapes (all four cases)

    func testGateCheckDecodesClear() async throws {
        StubURLProtocol.set { request in Self.ok(request, #"{"clear":{}}"#) }
        let result = try await makeClient().gateCheck(Self.gateRequest())
        XCTAssertEqual(result, .clear)
    }

    func testGateCheckDecodesCaseOpenWithNotices() async throws {
        StubURLProtocol.set { request in
            Self.ok(request, #"""
            {"caseOpen":{"_0":[{
                "noticeVersion":1,
                "caseId":"case-1",
                "authority":"onym:component:authority",
                "accused":"onym:key:0102",
                "mandateRef":"ref-1",
                "classId":"csam",
                "evidenceSummary":"summary",
                "responseDeadline":"2026-08-12T00:00:00Z",
                "decisionDeadline":"2026-08-19T00:00:00Z",
                "signature":"sig"
            }]}}
            """#)
        }
        let result = try await makeClient().gateCheck(Self.gateRequest())
        guard case .caseOpen(let notices) = result else {
            return XCTFail("expected caseOpen, got \(result)")
        }
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.caseId, "case-1")
        XCTAssertEqual(notices.first?.mandateRef, "ref-1")
        XCTAssertEqual(
            notices.first?.responseDeadline,
            Date(timeIntervalSince1970: 1_786_492_800)
        )
    }

    func testGateCheckDecodesBannedWithEmbeddedVerdict() async throws {
        StubURLProtocol.set { request in
            Self.ok(request, #"""
            {"banned":{"_0":{
                "verdictRef":"vr-1",
                "verdict":{
                    "verdictVersion":1,
                    "caseId":"case-1",
                    "authority":"onym:component:authority",
                    "mandateRef":"ref-1",
                    "accusedKeys":["onym:key:0102"],
                    "deviceBinding":"binding-1",
                    "classId":"csam",
                    "disposition":"ban",
                    "marks":{"case-open":false,"banned":true},
                    "banExpires":"2026-11-10T00:00:00.500Z",
                    "executeAfter":"2026-08-12T00:00:00Z",
                    "reasoning":"reasoning-address",
                    "appealDeadline":"2026-09-08T00:00:00Z",
                    "decidedAt":"2026-08-09T00:00:00Z",
                    "signature":"sig",
                    "final":false
                },
                "authorityContact":"onym:component:authority (see manifest)",
                "banExpires":"2026-11-10T00:00:00Z"
            }}}
            """#)
        }
        let result = try await makeClient().gateCheck(Self.gateRequest())
        guard case .banned(let state) = result else {
            return XCTFail("expected banned, got \(result)")
        }
        XCTAssertEqual(state.verdictRef, "vr-1")
        XCTAssertEqual(state.verdict?.caseId, "case-1")
        XCTAssertEqual(state.verdict?.disposition, .ban)
        // Fractional and whole-second RFC 3339 both decode.
        XCTAssertNotNil(state.verdict?.banExpires)
        XCTAssertNil(state.appealURL)
        XCTAssertNil(state.newHolderURL)
    }

    func testGateCheckDecodesCheckRequired() async throws {
        StubURLProtocol.set { request in
            Self.ok(request, #"{"checkRequired":{"_0":"tokenInvalid"}}"#)
        }
        let result = try await makeClient().gateCheck(Self.gateRequest())
        XCTAssertEqual(result, .checkRequired(.tokenInvalid))
    }

    // MARK: - Errors

    func testErrorEnvelopeSurfacesAsRejectedWithVerbatimCode() async throws {
        StubURLProtocol.set { request in
            (
                Data(#"{"error":"no_mandate","message":"no mandate on record"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await makeClient().gateCheck(Self.gateRequest())
            XCTFail("expected rejection")
        } catch let AuthorityClientError.rejected(rejection) {
            XCTAssertEqual(rejection.statusCode, 400)
            XCTAssertEqual(rejection.rawCode, "no_mandate")
            XCTAssertEqual(rejection.message, "no mandate on record")
        }
    }

    func testUndecodableSuccessBodySurfacesAsMalformedNotUnreachable() async throws {
        StubURLProtocol.set { request in Self.ok(request, #"{"unexpected":true}"#) }
        do {
            _ = try await makeClient().gateCheck(Self.gateRequest())
            XCTFail("expected malformed response")
        } catch AuthorityClientError.malformedResponse {
            // expected — a shape mismatch must fail loudly, not decode
            // into anything.
        }
    }

    func testInsecureBaseURLIsRefusedIncludingLoopback() async throws {
        // https-only in every build: even a loopback dev deployment
        // must come through an https proxy/tunnel, so no binary ever
        // carries an insecure-transport code path.
        for base in ["http://moderation.example", "http://localhost:8080", "http://127.0.0.1:8080"] {
            let insecure = URLSessionEnforcementBackendClient(
                baseURL: URL(string: base)!,
                session: session
            )
            do {
                _ = try await insecure.gateCheck(Self.gateRequest())
                XCTFail("expected insecure base URL to be refused: \(base)")
            } catch AuthorityClientError.insecureBaseURL {
                // expected
            }
        }
    }

    // MARK: - Helpers

    private static func gateRequest() -> GateCheckRequest {
        GateCheckRequest(
            deviceToken: nil,
            userKey: "onym:key:0102",
            mandateRef: "ref-1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            signature: Data("sig".utf8)
        )
    }
}
