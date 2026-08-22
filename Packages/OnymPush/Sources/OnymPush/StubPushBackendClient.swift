import CryptoKit
import Foundation

/// In-memory stand-in for tests and previews: records what was sent,
/// answers what it was told to.
public actor StubPushBackendClient: PushBackendClient {
    /// A pinned, deterministic, *valid* X25519 public key (derived
    /// from the fixed private scalar 0x11…11). All-zero bytes would
    /// decode but name a low-order point whose agreement CryptoKit
    /// rejects — sealing to it throws, and every default-stub register
    /// would silently vanish. Deterministic rather than fresh so
    /// fixtures and failures reproduce byte-for-byte.
    public static let defaultRegistrationKey: Data = {
        let scalar = Data(repeating: 0x11, count: 32)
        // swiftlint:disable:next force_try
        return try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
            .publicKey.rawRepresentation
    }()

    public private(set) var registered: [PushRegisterRequest] = []
    public private(set) var unregistered: [PushUnregisterRequest] = []

    public var registrationKeyAnswer: Data
    public var registerAnswer: Result<PushRegisterResponse, Error>
    public var unregisterAnswer: Result<Void, Error>
    /// Awaited inside `register` before the request is recorded — a
    /// test can hold a register "in flight" (e.g. behind a gate it
    /// controls) while it interleaves a disable, then let it land.
    public var onRegister: (@Sendable () async -> Void)?

    public init(
        registrationKeyAnswer: Data = StubPushBackendClient.defaultRegistrationKey,
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
        if let onRegister {
            await onRegister()
        }
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

    public func setUnregisterAnswer(_ answer: Result<Void, Error>) {
        unregisterAnswer = answer
    }

    public func setRegistrationKeyAnswer(_ key: Data) {
        registrationKeyAnswer = key
    }

    public func setOnRegister(_ hook: (@Sendable () async -> Void)?) {
        onRegister = hook
    }
}
