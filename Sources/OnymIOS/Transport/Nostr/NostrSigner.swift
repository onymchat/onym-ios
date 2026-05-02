import Foundation

/// BIP340 secp256k1 Schnorr signer over a Nostr event id. The transport
/// layer holds these but never constructs them — it asks a
/// `NostrEphemeralSignerProvider` for a fresh one per outgoing event so
/// `OnymSDK` stays out of this layer entirely.
protocol NostrSigner: Sendable {
    func publicKey() throws -> Data
    func signEventID(_ eventID: Data) throws -> Data
}

/// Source of fresh per-event signers for metadata-hiding outbound events
/// (kinds 44114 / 34113). Implemented by a repository-layer adapter that
/// owns the `OnymSDK` call site and the CSPRNG; injected into Nostr
/// transports at construction time.
protocol NostrEphemeralSignerProvider: Sendable {
    func makeEphemeralSigner() throws -> any NostrSigner
}

enum NostrSignerError: Error, Sendable {
    case invalidSecretKeyLength(actual: Int)
    case invalidEventIDLength(actual: Int)
    case csprngFailed(status: Int)
}
