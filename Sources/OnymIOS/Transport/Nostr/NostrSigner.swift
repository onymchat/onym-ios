import Foundation
import OnymSDK
import Security

/// BIP340 secp256k1 Schnorr signer over a Nostr event id. The transport
/// layer never sees the secret key — it only asks for the x-only public
/// key (32 bytes) and a signature (64 bytes) for a given event id.
protocol NostrSigner: Sendable {
    func publicKey() throws -> Data
    func signEventID(_ eventID: Data) throws -> Data
}

/// `NostrSigner` backed by a 32-byte secp256k1 secret. The signer uses
/// `OnymSDK.Common` for the underlying BIP340 operations.
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

    /// Per-event ephemeral signer backed by a fresh CSPRNG-derived secret.
    /// Used for metadata-hiding kinds (44114 / 34113) so the outer event
    /// `pubkey` can't be used to cluster co-membership.
    static func ephemeral() throws -> OnymNostrSigner {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            throw NostrSignerError.csprngFailed(status: Int(status))
        }
        return try OnymNostrSigner(secretKey: Data(bytes))
    }
}

enum NostrSignerError: Error, Sendable {
    case invalidSecretKeyLength(actual: Int)
    case invalidEventIDLength(actual: Int)
    case csprngFailed(status: Int)
}
