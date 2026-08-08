import CryptoKit
import Foundation
import OnymTransport
import OnymTransportNostr

/// Descriptor returned by a Blossom server for a stored blob (BUD-02).
public struct BlobDescriptor: Equatable, Sendable {
    /// Lowercase hex SHA-256 of the stored bytes — the blob's address.
    let sha256: String
    /// Absolute URL the blob can be fetched from.
    let url: String
    /// Stored size in bytes.
    let size: Int

    public init(sha256: String, url: String, size: Int) {
        self.sha256 = sha256
        self.url = url
        self.size = size
    }
}

/// Uploads/downloads opaque blobs to a Blossom media server
/// (`blossom.onym.app`, the reference `hzrd149/blossom-server`). Chat
/// images are AES-GCM-encrypted (`ChatImageCrypto`) before upload, so
/// the bytes crossing this seam are always ciphertext.
///
/// A protocol so the UI-test harness can swap in an in-memory store the
/// same way it swaps the inbox transport + chain ledger.
public protocol BlossomClient: Sendable {
    /// `PUT /upload` the blob (BUD-01 auth). Returns its descriptor.
    func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor
    /// `GET /<sha256>` the blob. Callers verify the hash before use.
    func download(sha256: String) async throws -> Data
}

public enum BlossomError: Error, Equatable {
    case badStatus(Int)
    case malformedResponse
    case invalidURL
}

/// Production `BlossomClient` over `URLSession`. Uploads carry a BUD-01
/// `Authorization: Nostr <base64(kind:24242 event)>` header, signed by
/// an ephemeral Nostr key (the server just needs a valid signature over
/// the blob hash; no stable identity is exposed). Downloads are
/// unauthenticated `GET`s by hash.
public struct URLSessionBlossomClient: BlossomClient {
    let baseURL: URL
    let signerProvider: any NostrEphemeralSignerProvider
    var session: URLSession = .shared
    /// How long an upload auth event stays valid (BUD-01 `expiration`).
    var authTTLSeconds: Int64 = 300

    public static let defaultBaseURL = URL(string: "https://blossom.onym.app")!

    public init(
        baseURL: URL,
        signerProvider: any NostrEphemeralSignerProvider,
        session: URLSession = .shared,
        authTTLSeconds: Int64 = 300
    ) {
        self.baseURL = baseURL
        self.signerProvider = signerProvider
        self.session = session
        self.authTTLSeconds = authTTLSeconds
    }

    public func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
        let sha = Self.sha256Hex(blob)
        let signer = try signerProvider.makeEphemeralSigner()
        let auth = try Self.authorizationHeader(
            action: "upload", sha256: sha, ttlSeconds: authTTLSeconds, signer: signer
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("upload"))
        request.httpMethod = "PUT"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, from: blob)
        guard let http = response as? HTTPURLResponse else { throw BlossomError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw BlossomError.badStatus(http.statusCode) }
        return try Self.decodeDescriptor(data, fallbackSha256: sha)
    }

    public func download(sha256: String) async throws -> Data {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent(sha256))
        guard let http = response as? HTTPURLResponse else { throw BlossomError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw BlossomError.badStatus(http.statusCode) }
        return data
    }

    // MARK: - Helpers (public for tests)

    /// Build the BUD-01 authorization header value for `action` over the
    /// blob `sha256`. Exposed so tests can assert the event shape
    /// without a live server.
    public static func authorizationHeader(
        action: String,
        sha256: String,
        ttlSeconds: Int64,
        signer: NostrSigner
    ) throws -> String {
        let expiration = Int64(Date().timeIntervalSince1970) + ttlSeconds
        let event = try NostrEvent.build(
            kind: 24242,
            tags: [
                ["t", action],
                ["x", sha256],
                ["expiration", String(expiration)],
            ],
            content: "Upload chat image",
            signer: signer
        )
        let eventJSON = try JSONEncoder().encode(event)
        return "Nostr \(eventJSON.base64EncodedString())"
    }

    /// Lowercase hex SHA-256 of `data`. Local copy of
    /// `ChatImageCrypto.sha256Hex` — the crypto helper stays in the app
    /// module, and this package only needs the blob address.
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeDescriptor(_ data: Data, fallbackSha256: String) throws -> BlobDescriptor {
        struct Wire: Decodable {
            let sha256: String?
            let url: String?
            let size: Int?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw BlossomError.malformedResponse
        }
        let sha = wire.sha256 ?? fallbackSha256
        return BlobDescriptor(
            sha256: sha,
            url: wire.url ?? "",
            size: wire.size ?? 0
        )
    }
}
