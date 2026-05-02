import XCTest
@testable import OnymIOS

/// Pure-Swift unit tests for `SEPContractClient` — no real HTTP. A
/// `RecordingTransport` captures the encoded invocation and returns a
/// canned response, so we verify both the wire shape (camelCase
/// envelope, snake_case payload, contractType + network top-level) and
/// the client's response decoding without touching `URLSession`.
final class SEPContractClientTests: XCTestCase {
    private let testContractID = "CONTRACTID000000000000000000000000000000000000000000000000"

    // MARK: - Envelope shape

    func test_createGroupTyranny_sendsCorrectEnvelopeAndPayload() async throws {
        let recorder = RecordingTransport(
            response: SEPSubmissionResponse(
                accepted: true,
                transactionHash: "abc123",
                message: nil
            )
        )
        let client = SEPContractClient(
            contractID: testContractID,
            contractType: .tyranny,
            network: .testnet,
            transport: recorder
        )

        let payload = TyrannyCreateGroupPayload(
            groupID: Data(repeating: 0xAB, count: 32),
            commitment: Data(repeating: 0xCD, count: 32),
            tier: SEPTier.small.rawValue,
            adminPubkeyCommitment: Data(repeating: 0x42, count: 32),
            proof: Data(repeating: 0xEE, count: 1601),
            publicInputs: [
                Data(repeating: 0xCD, count: 32),
                Data(repeating: 0x00, count: 32),
                Data(repeating: 0x42, count: 32),
                Data(repeating: 0x77, count: 32),
            ]
        )
        let response = try await client.createGroupTyranny(payload)

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.transactionHash, "abc123")

        let json = try XCTUnwrap(recorder.lastJSON())
        // Top-level envelope (camelCase per relayer's RelayerRequest)
        XCTAssertEqual(json["function"] as? String, "create_group")
        XCTAssertEqual(json["contractID"] as? String, testContractID)
        XCTAssertEqual(json["contractType"] as? String, "tyranny")
        XCTAssertEqual(json["network"] as? String, "testnet")

        // Payload (snake_case for the contract args)
        let payloadJSON = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual((payloadJSON["tier"] as? NSNumber)?.intValue, 0)
        XCTAssertNotNil(payloadJSON["group_id"])
        XCTAssertNotNil(payloadJSON["admin_pubkey_commitment"])
        XCTAssertNotNil(payloadJSON["proof"])
        let publicInputs = try XCTUnwrap(payloadJSON["publicInputs"] as? [String])
        XCTAssertEqual(publicInputs.count, 4, "Tyranny create needs 4 PI entries")
    }

    func test_createGroupTyranny_mainnetSerializesAsPublic() async throws {
        let recorder = RecordingTransport(
            response: SEPSubmissionResponse(accepted: true, transactionHash: nil, message: nil)
        )
        let client = SEPContractClient(
            contractID: testContractID,
            contractType: .tyranny,
            network: .publicNet,
            transport: recorder
        )
        _ = try await client.createGroupTyranny(stubPayload())

        let json = try XCTUnwrap(recorder.lastJSON())
        XCTAssertEqual(json["network"] as? String, "public",
                       "mainnet must serialise as `public` to match Stellar's terminology + relayer enum")
    }

    func test_getCommitment_routesToGetCommitmentFunction() async throws {
        let entry = SEPCommitmentEntry(
            commitment: Data(repeating: 0x09, count: 32),
            epoch: 7,
            timestamp: 1_700_000_000,
            tier: 0,
            active: true
        )
        let recorder = RecordingTransport(response: entry)
        let client = SEPContractClient(
            contractID: testContractID,
            contractType: .tyranny,
            network: .testnet,
            transport: recorder
        )

        let result = try await client.getCommitment(groupID: Data(repeating: 0x55, count: 32))
        XCTAssertEqual(result, entry)

        let json = try XCTUnwrap(recorder.lastJSON())
        XCTAssertEqual(json["function"] as? String, "get_commitment")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertNotNil(payload["group_id"])
    }

    // MARK: - URLSession transport

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
        let client = SEPContractClient(
            contractID: testContractID,
            contractType: .tyranny,
            network: .testnet,
            transport: transport
        )

        do {
            _ = try await client.getCommitment(groupID: Data(repeating: 0, count: 32))
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
        let client = SEPContractClient(
            contractID: testContractID,
            contractType: .tyranny,
            network: .testnet,
            transport: transport
        )

        let response = try await client.createGroupTyranny(stubPayload())
        XCTAssertEqual(response, stub)
    }

    // MARK: - Helpers

    private func stubPayload() -> TyrannyCreateGroupPayload {
        TyrannyCreateGroupPayload(
            groupID: Data(repeating: 0, count: 32),
            commitment: Data(repeating: 0, count: 32),
            tier: 0,
            adminPubkeyCommitment: Data(repeating: 0, count: 32),
            proof: Data(repeating: 0, count: 1601),
            publicInputs: Array(repeating: Data(repeating: 0, count: 32), count: 4)
        )
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
