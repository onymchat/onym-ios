import XCTest
@testable import OnymPush

/// Wire tests for `URLSessionPushBackendClient` against the push
/// backend's shapes: camelCase + base64 `Data` request bodies, the
/// `{error, message}` refusal envelope kept verbatim, and the
/// https-only guard that no build relaxes.
final class PushBackendClientTests: XCTestCase {
    private let baseURL = URL(string: "https://push.example")!
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

    private func makeClient(baseURL: URL? = nil) -> URLSessionPushBackendClient {
        URLSessionPushBackendClient(baseURL: baseURL ?? self.baseURL, session: session)
    }

    private func makeRegisterRequest(deviceToken: Data? = nil) throws -> PushRegisterRequest {
        PushRegisterRequest(
            deviceToken: deviceToken,
            userKey: "onym:key:aabb",
            timestamp: ISO8601DateFormatter.push.date(from: "2026-08-22T12:00:00Z")!,
            signature: Data([0x01]),
            tokenEnvelope: PushTokenEnvelope(
                ephemeralPublicKey: Data(repeating: 1, count: 32),
                nonce: Data(repeating: 2, count: 12),
                ciphertext: Data([0x03]),
                authenticationTag: Data(repeating: 4, count: 16)
            ),
            subscriptions: [PushSubscription(tag: "a1b2c3d4e5f60718", relays: ["wss://nostr.onym.app"])]
        )
    }

    /// What the URLProtocol handler saw of one request.
    struct RecordedWire {
        let url: String?
        let body: Data?
    }

    /// Records the request URL and (streamed) body, answering `payload`
    /// with `status`. The handler runs on the URL loading system's
    /// thread; `Recorder` carries the value back safely.
    private func recordRequests(
        into recorded: Recorder<RecordedWire>,
        status: Int = 200,
        payload: Data = Data()
    ) {
        StubURLProtocol.set(handler: { request in
            let body = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }
            recorded.record(RecordedWire(url: request.url?.absoluteString, body: body))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (payload, response)
        })
    }

    func testInsecureBaseURLIsRefusedBeforeAnyRequest() async throws {
        let client = makeClient(baseURL: URL(string: "http://push.example")!)
        do {
            _ = try await client.registrationKey()
            XCTFail("http must be refused")
        } catch let PushClientError.insecureBaseURL(url) {
            XCTAssertEqual(url, "http://push.example")
        }
    }

    func testRegisterSendsCamelCaseBase64Body() async throws {
        let recorded = Recorder<RecordedWire>()
        recordRequests(
            into: recorded,
            payload: Data(#"{"expiresAt":"2026-10-21T12:00:00Z"}"#.utf8)
        )

        let response = try await makeClient().register(makeRegisterRequest())
        XCTAssertEqual(recorded.value?.url, "https://push.example/v1/register")
        let body = try JSONSerialization.jsonObject(
            with: recorded.value?.body ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(body?["userKey"] as? String, "onym:key:aabb")
        XCTAssertEqual(body?["timestamp"] as? String, "2026-08-22T12:00:00Z")
        // A nil attestation token omits the key entirely — that
        // missing-key form is the backend's contract (serde reads an
        // absent `Option` as `None`), pinned here so a "helpful"
        // null-encoding change fails a test, not production.
        XCTAssertNil(body?["deviceToken"])
        let envelope = body?["tokenEnvelope"] as? [String: Any]
        XCTAssertEqual(
            envelope?["ephemeralPublicKey"] as? String,
            Data(repeating: 1, count: 32).base64EncodedString()
        )
        let subscriptions = body?["subscriptions"] as? [[String: Any]]
        XCTAssertEqual(subscriptions?.first?["tag"] as? String, "a1b2c3d4e5f60718")
        XCTAssertEqual(
            response.expiresAt,
            ISO8601DateFormatter.push.date(from: "2026-10-21T12:00:00Z")
        )
    }

    func testRegisterSendsPresentDeviceTokenAsBase64() async throws {
        let recorded = Recorder<RecordedWire>()
        recordRequests(
            into: recorded,
            payload: Data(#"{"expiresAt":"2026-10-21T12:00:00Z"}"#.utf8)
        )
        let attestation = Data("device-token".utf8)

        _ = try await makeClient().register(makeRegisterRequest(deviceToken: attestation))
        let body = try JSONSerialization.jsonObject(
            with: recorded.value?.body ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(body?["deviceToken"] as? String, attestation.base64EncodedString())
    }

    /// The unregister wire: `POST /v1/unregister`, the same camelCase
    /// base64 body shape minus subscriptions, and an empty 200 counts
    /// as success — there is nothing to decode.
    func testUnregisterSendsBodyAndAcceptsEmptyOK() async throws {
        let recorded = Recorder<RecordedWire>()
        recordRequests(into: recorded)

        try await makeClient().unregister(
            PushUnregisterRequest(
                deviceToken: nil,
                userKey: "onym:key:aabb",
                timestamp: ISO8601DateFormatter.push.date(from: "2026-08-22T12:00:00Z")!,
                signature: Data([0x02]),
                tokenEnvelope: PushTokenEnvelope(
                    ephemeralPublicKey: Data(repeating: 1, count: 32),
                    nonce: Data(repeating: 2, count: 12),
                    ciphertext: Data([0x03]),
                    authenticationTag: Data(repeating: 4, count: 16)
                )
            )
        )

        XCTAssertEqual(recorded.value?.url, "https://push.example/v1/unregister")
        let body = try JSONSerialization.jsonObject(
            with: recorded.value?.body ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(body?["userKey"] as? String, "onym:key:aabb")
        XCTAssertEqual(body?["timestamp"] as? String, "2026-08-22T12:00:00Z")
        XCTAssertNil(body?["deviceToken"])
        XCTAssertEqual(body?["signature"] as? String, Data([0x02]).base64EncodedString())
        XCTAssertNil(body?["subscriptions"])
        let envelope = body?["tokenEnvelope"] as? [String: Any]
        XCTAssertEqual(
            envelope?["nonce"] as? String,
            Data(repeating: 2, count: 12).base64EncodedString()
        )
    }

    /// A refusal whose body is not the `{error, message}` envelope (a
    /// proxy's HTML, an empty body) still surfaces typed: the
    /// synthetic `http_<status>` code, not a decode error.
    func testNonEnvelopeRefusalFallsBackToSyntheticCode() async throws {
        StubURLProtocol.set(handler: { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
            )!
            return (Data("<html>upstream unavailable</html>".utf8), response)
        })
        do {
            _ = try await makeClient().register(makeRegisterRequest())
            XCTFail("503 must throw")
        } catch let PushClientError.rejected(rejection) {
            XCTAssertEqual(rejection.statusCode, 503)
            XCTAssertEqual(rejection.rawCode, "http_503")
            XCTAssertEqual(rejection.code, .unknown("http_503"))
        }
    }

    /// RFC 3339 permits fractional seconds and Foundation's `.iso8601`
    /// strategy does not — the dual-formatter decode is the client's
    /// sole reason both shapes work, so the fractional one is pinned.
    func testFractionalSecondsExpiryDecodes() async throws {
        let recorded = Recorder<RecordedWire>()
        recordRequests(
            into: recorded,
            payload: Data(#"{"expiresAt":"2026-10-21T12:00:00.250Z"}"#.utf8)
        )
        let response = try await makeClient().register(makeRegisterRequest())
        let whole = ISO8601DateFormatter.push.date(from: "2026-10-21T12:00:00Z")!
        XCTAssertEqual(response.expiresAt.timeIntervalSince(whole), 0.25, accuracy: 0.001)
    }

    /// The other half of the transport guard: an https scheme with an
    /// *empty* host (`https:///`) is refused before any request, same
    /// as a non-https scheme.
    func testEmptyHostHTTPSBaseURLIsRefused() async throws {
        let client = makeClient(baseURL: URL(string: "https:///push")!)
        do {
            _ = try await client.registrationKey()
            XCTFail("an empty host must be refused")
        } catch let PushClientError.insecureBaseURL(url) {
            XCTAssertEqual(url, "https:///push")
        }
    }

    func testRefusalEnvelopeSurfacesVerbatim() async throws {
        StubURLProtocol.set(handler: { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (
                Data(#"{"error":"signature_invalid","message":"session signature already used"}"#.utf8),
                response
            )
        })
        do {
            _ = try await makeClient().register(makeRegisterRequest())
            XCTFail("401 must throw")
        } catch let PushClientError.rejected(rejection) {
            XCTAssertEqual(rejection.statusCode, 401)
            XCTAssertEqual(rejection.rawCode, "signature_invalid")
            XCTAssertEqual(rejection.message, "session signature already used")
        }
    }

    func testRegistrationKeyDecodesBase64() async throws {
        let key = Data(repeating: 7, count: 32)
        StubURLProtocol.set(handler: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://push.example/v1/registration-key")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"publicKey":"\#(key.base64EncodedString())"}"#.utf8), response)
        })
        let fetched = try await makeClient().registrationKey()
        XCTAssertEqual(fetched, key)
    }
}
