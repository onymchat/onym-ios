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

    private func makeRegisterRequest() throws -> PushRegisterRequest {
        PushRegisterRequest(
            deviceToken: nil,
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
        let recorded = NSMutableDictionary()
        StubURLProtocol.set(handler: { request in
            recorded["url"] = request.url?.absoluteString
            recorded["body"] = request.httpBody ?? request.httpBodyStream.map { stream in
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
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(#"{"expiresAt":"2026-10-21T12:00:00Z"}"#.utf8), response)
        })

        let response = try await makeClient().register(makeRegisterRequest())
        XCTAssertEqual(recorded["url"] as? String, "https://push.example/v1/register")
        let body = try JSONSerialization.jsonObject(
            with: recorded["body"] as? Data ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(body?["userKey"] as? String, "onym:key:aabb")
        XCTAssertEqual(body?["timestamp"] as? String, "2026-08-22T12:00:00Z")
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
