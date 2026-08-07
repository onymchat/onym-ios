import Foundation

/// Descriptor returned by a Blossom server for a stored blob (BUD-02).
struct BlobDescriptor: Equatable, Sendable {
    /// Lowercase hex SHA-256 of the stored bytes — the blob's address.
    let sha256: String
    /// Absolute URL the blob can be fetched from.
    let url: String
    /// Stored size in bytes.
    let size: Int
}

/// Uploads/downloads opaque blobs to a Blossom media server
/// (`blossom.onym.app`, the reference `hzrd149/blossom-server`). Chat
/// images are AES-GCM-encrypted (`ChatImageCrypto`) before upload, so
/// the bytes crossing this seam are always ciphertext.
///
/// A protocol so the UI-test harness can swap in an in-memory store the
/// same way it swaps the inbox transport + chain ledger.
protocol BlossomClient: Sendable {
    /// `PUT /upload` the blob (BUD-01 auth). Returns its descriptor.
    func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor
    /// `GET /<sha256>` the blob. Callers verify the hash before use.
    func download(sha256: String) async throws -> Data
}

enum BlossomError: Error, Equatable {
    case badStatus(Int)
    case malformedResponse
    case invalidURL
}

/// Production `BlossomClient` over `URLSession`. Uploads carry a BUD-01
/// `Authorization: Nostr <base64(kind:24242 event)>` header, signed by
/// an ephemeral Nostr key (the server just needs a valid signature over
/// the blob hash; no stable identity is exposed). Downloads are
/// unauthenticated `GET`s by hash.
struct URLSessionBlossomClient: BlossomClient {
    let baseURL: URL
    let signerProvider: any NostrEphemeralSignerProvider
    var session: URLSession = .shared
    /// How long an upload auth event stays valid (BUD-01 `expiration`).
    var authTTLSeconds: Int64 = 300

    static let defaultBaseURL = URL(string: "https://blossom.onym.app")!

    func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
        let sha = ChatImageCrypto.sha256Hex(blob)
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

    func download(sha256: String) async throws -> Data {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent(sha256))
        guard let http = response as? HTTPURLResponse else { throw BlossomError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw BlossomError.badStatus(http.statusCode) }
        return data
    }

    // MARK: - Helpers (internal for tests)

    /// Build the BUD-01 authorization header value for `action` over the
    /// blob `sha256`. Exposed at `internal` so tests can assert the
    /// event shape without a live server.
    static func authorizationHeader(
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
