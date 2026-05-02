import Foundation

/// Generic envelope wrapping a contract-function invocation. Mirrors
/// `swift-mls`'s `SEPContractInvocation` so the relayer wire format stays
/// in sync — the relayer reads `contract_id`, `function`, and `payload`
/// out of the JSON top-level. Stellar Soroban SDK is intentionally not
/// pulled in: relayers handle tx assembly + signing, this client just
/// posts the function call.
struct SEPContractInvocation<Payload: Encodable & Sendable>: Encodable, Sendable {
    let contractID: String
    let function: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case contractID = "contract_id"
        case function
        case payload
    }
}

/// Seam for the network leg. Tests inject a fake; production uses
/// `URLSessionSEPContractTransport` constructed from a `RelayerEndpoint`
/// resolved via `RelayerSelectionStrategy`.
protocol SEPContractTransport: Sendable {
    func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ invocation: SEPContractInvocation<Payload>,
        responseType: Response.Type
    ) async throws -> Response
}

struct URLSessionSEPContractTransport: SEPContractTransport {
    let endpoint: URL
    let session: URLSession
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init(
        endpoint: URL,
        session: URLSession = .shared,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.endpoint = endpoint
        self.session = session
        self.encoder = encoder
        self.decoder = decoder
    }

    func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ invocation: SEPContractInvocation<Payload>,
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(invocation)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            throw SEPError.invalidResponse(statusCode: statusCode, body: body)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw SEPError.decodeFailure(String(describing: error))
        }
    }
}

/// Pins a `(contractID, transport)` pair and exposes the four contract
/// entrypoints PR-A needs: `create_group_v2` (Anarchy / 1v1 / Democracy /
/// Tyranny), `update_commitment` (Tyranny member-add later), `get_state`
/// (post-create read-back). Per-type Oligarchy creation lives outside
/// PR-A scope.
struct SEPContractClient: Sendable {
    let contractID: String
    let transport: any SEPContractTransport

    init(contractID: String, transport: any SEPContractTransport) {
        self.contractID = contractID
        self.transport = transport
    }

    func createGroupV2(_ request: SEPCreateGroupV2Request) async throws -> SEPSubmissionResponse {
        try await invoke("create_group_v2", payload: request, responseType: SEPSubmissionResponse.self)
    }

    func updateCommitment(_ request: SEPUpdateCommitmentRequest) async throws -> SEPSubmissionResponse {
        try await invoke("update_commitment", payload: request, responseType: SEPSubmissionResponse.self)
    }

    func getState(groupID: Data) async throws -> SEPCommitmentEntry {
        try await invoke(
            "get_state",
            payload: SEPGetStateRequest(groupID: groupID),
            responseType: SEPCommitmentEntry.self
        )
    }

    private func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ function: String,
        payload: Payload,
        responseType: Response.Type
    ) async throws -> Response {
        try await transport.invoke(
            SEPContractInvocation(contractID: contractID, function: function, payload: payload),
            responseType: responseType
        )
    }
}
