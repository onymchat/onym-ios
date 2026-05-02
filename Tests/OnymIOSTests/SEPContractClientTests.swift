import XCTest
@testable import OnymIOS

/// Pure-Swift unit tests for `SEPContractClient` — no real HTTP. A
/// `RecordingTransport` captures the encoded invocation and returns a
/// canned response, so we verify both the wire shape (snake_case keys,
/// envelope structure) and the client's response decoding without
/// touching `URLSession`.
final class SEPContractClientTests: XCTestCase {
    private let testContractID = "CONTRACTID000000000000000000000000000000000000000000000000"

    func test_createGroupV2_sendsSnakeCasePayload() async throws {
        let recorder = RecordingTransport(
            response: SEPSubmissionResponse(
                accepted: true,
                transactionHash: "abc123",
                message: nil
            )
        )
        let client = SEPContractClient(contractID: testContractID, transport: recorder)

        let request = SEPCreateGroupV2Request(
            caller: "GBABCDEF",
            groupID: Data(repeating: 0xAB, count: 32),
            commitment: Data(repeating: 0xCD, count: 32),
            tier: UInt32(SEPTier.small.rawValue),
            groupType: .tyranny,
            memberCount: 1,
            proof: Data(repeating: 0xEE, count: 64),
            publicInputs: SEPPublicInputs(
                commitment: Data(repeating: 0xCD, count: 32),
                epoch: 0
            )
        )
        let response = try await client.createGroupV2(request)

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.transactionHash, "abc123")

        let json = try XCTUnwrap(recorder.lastJSON())
        XCTAssertEqual(json["function"] as? String, "create_group_v2")
        XCTAssertEqual(json["contract_id"] as? String, testContractID)
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["caller"] as? String, "GBABCDEF")
        XCTAssertEqual((payload["group_type"] as? NSNumber)?.uint32Value, SEPGroupType.tyranny.rawValue)
        XCTAssertEqual((payload["member_count"] as? NSNumber)?.uint32Value, 1)
        XCTAssertNotNil(payload["group_id"])  // Data → base64 string in JSON
        XCTAssertNotNil(payload["public_inputs"])
    }

    func test_updateCommitment_routesToUpdateFunction() async throws {
        let recorder = RecordingTransport(
            response: SEPSubmissionResponse(accepted: true, transactionHash: nil, message: nil)
        )
        let client = SEPContractClient(contractID: testContractID, transport: recorder)

        let request = SEPUpdateCommitmentRequest(
            groupID: Data(repeating: 0x01, count: 32),
            proof: Data(repeating: 0x02, count: 32),
            publicInputs: SEPUpdatePublicInputs(
                cOld: Data(repeating: 0x03, count: 32),
                epochOld: 1,
                cNew: Data(repeating: 0x04, count: 32)
            )
        )
        _ = try await client.updateCommitment(request)

        let json = try XCTUnwrap(recorder.lastJSON())
        XCTAssertEqual(json["function"] as? String, "update_commitment")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let publicInputs = try XCTUnwrap(payload["public_inputs"] as? [String: Any])
        XCTAssertNotNil(publicInputs["c_old"])
        XCTAssertNotNil(publicInputs["c_new"])
        XCTAssertEqual((publicInputs["epoch_old"] as? NSNumber)?.uint64Value, 1)
    }

    func test_getState_sendsGroupIdInGetStateEnvelope() async throws {
        let entry = SEPCommitmentEntry(
            commitment: Data(repeating: 0x09, count: 32),
            epoch: 7,
            timestamp: 1_700_000_000,
            tier: 0,
            active: true
        )
        let recorder = RecordingTransport(response: entry)
        let client = SEPContractClient(contractID: testContractID, transport: recorder)

        let result = try await client.getState(groupID: Data(repeating: 0x55, count: 32))
        XCTAssertEqual(result, entry)

        let json = try XCTUnwrap(recorder.lastJSON())
        XCTAssertEqual(json["function"] as? String, "get_state")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertNotNil(payload["group_id"])
    }

    func test_urlSessionTransport_throwsOnNon2xx() async throws {
        let url = URL(string: "https://example.invalid/contract")!
        StubURLProtocol.set(handler: { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            return (Data("boom".utf8), response)
        })
        defer { StubURLProtocol.reset() }
        let session = StubURLProtocol.makeSession()
        let transport = URLSessionSEPContractTransport(endpoint: url, session: session)
        let client = SEPContractClient(contractID: testContractID, transport: transport)

        do {
            _ = try await client.getState(groupID: Data(repeating: 0, count: 32))
            XCTFail("expected SEPError.invalidResponse")
        } catch let SEPError.invalidResponse(statusCode, body) {
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(body, "boom")
        }
    }

    func test_urlSessionTransport_decodes2xxResponse() async throws {
        let url = URL(string: "https://example.invalid/contract")!
        let stub = SEPSubmissionResponse(
            accepted: true,
            transactionHash: "deadbeef",
            message: "ok"
        )
        let body = try JSONEncoder().encode(stub)
        StubURLProtocol.set(handler: { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        })
        defer { StubURLProtocol.reset() }
        let session = StubURLProtocol.makeSession()
        let transport = URLSessionSEPContractTransport(endpoint: url, session: session)
        let client = SEPContractClient(contractID: testContractID, transport: transport)

        let request = SEPCreateGroupV2Request(
            caller: "GBABCDEF",
            groupID: Data(repeating: 0, count: 32),
            commitment: Data(repeating: 0, count: 32),
            tier: 0,
            groupType: .tyranny,
            memberCount: 1,
            proof: Data(),
            publicInputs: SEPPublicInputs(commitment: Data(repeating: 0, count: 32), epoch: 0)
        )
        let response = try await client.createGroupV2(request)
        XCTAssertEqual(response, stub)
    }
}

// MARK: - Recording transport

private final class RecordingTransport<Stub: Encodable & Sendable>: SEPContractTransport, @unchecked Sendable {
    private let stub: Stub
    private let lock = NSLock()
    private var lastBody: Data?

    init(response: Stub) {
        self.stub = response
    }

    func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ invocation: SEPContractInvocation<Payload>,
        responseType: Response.Type
    ) async throws -> Response {
        let encoded = try JSONEncoder().encode(invocation)
        lock.withLock { lastBody = encoded }
        let stubData = try JSONEncoder().encode(stub)
        return try JSONDecoder().decode(Response.self, from: stubData)
    }

    func lastJSON() -> [String: Any]? {
        guard let data = lock.withLock({ lastBody }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
