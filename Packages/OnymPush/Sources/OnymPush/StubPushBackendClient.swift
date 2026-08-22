import Foundation

/// In-memory stand-in for tests and previews: records what was sent,
/// answers what it was told to.
public actor StubPushBackendClient: PushBackendClient {
    public private(set) var registered: [PushRegisterRequest] = []
    public private(set) var unregistered: [PushUnregisterRequest] = []

    /// 32 zero bytes decodes as a valid X25519 public key; tests that
    /// care set a real one.
    public var registrationKeyAnswer: Data
    public var registerAnswer: Result<PushRegisterResponse, Error>
    public var unregisterAnswer: Result<Void, Error>

    public init(
        registrationKeyAnswer: Data = Data(repeating: 0, count: 32),
        registerAnswer: Result<PushRegisterResponse, Error> =
            .success(PushRegisterResponse(expiresAt: .distantFuture)),
        unregisterAnswer: Result<Void, Error> = .success(())
    ) {
        self.registrationKeyAnswer = registrationKeyAnswer
        self.registerAnswer = registerAnswer
        self.unregisterAnswer = unregisterAnswer
    }

    public func registrationKey() async throws -> Data {
        registrationKeyAnswer
    }

    public func register(_ request: PushRegisterRequest) async throws -> PushRegisterResponse {
        registered.append(request)
        return try registerAnswer.get()
    }

    public func unregister(_ request: PushUnregisterRequest) async throws {
        unregistered.append(request)
        try unregisterAnswer.get()
    }

    public func setRegisterAnswer(_ answer: Result<PushRegisterResponse, Error>) {
        registerAnswer = answer
    }

    public func setRegistrationKeyAnswer(_ key: Data) {
        registrationKeyAnswer = key
    }
}
