import Foundation
import OnymSDK
import Security

/// `NostrSigner` backed by a 32-byte secp256k1 secret. Uses
/// `OnymSDK.Common` for the underlying BIP340 operations. Lives in the
/// Identity layer (alongside the only other `OnymSDK` consumer,
/// `IdentityRepository`) so the Transport seam never imports `OnymSDK`.
struct OnymNostrSigner: NostrSigner {
    let secretKey: Data

    init(secretKey: Data) throws {
        guard secretKey.count == 32 else {
            throw NostrSignerError.invalidSecretKeyLength(actual: secretKey.count)
        }
        self.secretKey = secretKey
    }

    func publicKey() throws -> Data {
        try Common.nostrDerivePublicKey(secretKey: secretKey)
    }

    func signEventID(_ eventID: Data) throws -> Data {
        guard eventID.count == 32 else {
            throw NostrSignerError.invalidEventIDLength(actual: eventID.count)
        }
        return try Common.nostrSignEventId(secretKey: secretKey, eventId: eventID)
    }

    /// Per-event ephemeral signer backed by a fresh CSPRNG-derived
    /// secret. Construction-time convenience used by the production
    /// signer provider and by tests; production callers in the Transport
    /// layer go through `NostrEphemeralSignerProvider` instead.
    static func ephemeral() throws -> OnymNostrSigner {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw NostrSignerError.csprngFailed(status: Int(status))
        }
        return try OnymNostrSigner(secretKey: Data(bytes))
    }
}

/// Production `NostrEphemeralSignerProvider`. Stateless; owns no
/// secret material itself — every call returns a fresh `OnymNostrSigner`
/// with its own freshly-randomised secret. Safe to share.
struct OnymNostrSignerProvider: NostrEphemeralSignerProvider {
    func makeEphemeralSigner() throws -> any NostrSigner {
        try OnymNostrSigner.ephemeral()
    }
}
