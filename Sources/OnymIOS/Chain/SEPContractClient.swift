import Foundation

/// Seam for the network leg. Tests inject a fake; production uses
/// `URLSessionSEPContractTransport` constructed from a `RelayerEndpoint`
/// resolved by `RelayerRepository.selectURL`.
///
/// The `SEPContractInvocation` envelope itself lives in
/// `SEPContractTypes.swift` so the wire-format types stay together.
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

/// Pins a `(contractID, contractType, network, transport)` tuple and
/// exposes the per-function entrypoints PR-C needs:
/// `create_group` (Tyranny only at this slice), `update_commitment`,
/// `get_commitment`. Top-level fields are stamped onto every
/// invocation so the relayer can route + allowlist-check.
struct SEPContractClient: Sendable {
    let contractID: String
    let contractType: SEPGroupType
    let network: SEPNetwork
    let transport: any SEPContractTransport

    init(
        contractID: String,
        contractType: SEPGroupType,
        network: SEPNetwork,
        transport: any SEPContractTransport
    ) {
        self.contractID = contractID
        self.contractType = contractType
        self.network = network
        self.transport = transport
    }

    func createGroupTyranny(_ payload: TyrannyCreateGroupPayload) async throws -> SEPSubmissionResponse {
        try await invoke("create_group", payload: payload, responseType: SEPSubmissionResponse.self)
    }

    func updateCommitmentTyranny(_ payload: TyrannyUpdateCommitmentPayload) async throws -> SEPSubmissionResponse {
        try await invoke("update_commitment", payload: payload, responseType: SEPSubmissionResponse.self)
    }

    func getCommitment(groupID: Data) async throws -> SEPCommitmentEntry {
        try await invoke(
            "get_commitment",
            payload: GetCommitmentPayload(groupID: groupID),
            responseType: SEPCommitmentEntry.self
        )
    }

    private func invoke<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        _ function: String,
        payload: Payload,
        responseType: Response.Type
    ) async throws -> Response {
        try await transport.invoke(
            SEPContractInvocation(
                contractID: contractID,
                contractType: contractType,
                network: network,
                function: function,
                payload: payload
            ),
            responseType: responseType
        )
    }
}
