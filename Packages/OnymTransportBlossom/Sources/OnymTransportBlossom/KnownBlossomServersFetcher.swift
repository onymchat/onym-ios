import Foundation
import OnymFoundation

/// Fetches the Onym-published default Blossom-server list from a GitHub
/// release asset. Mirrors `KnownNostrRelaysFetcher` / the chain relayer's
/// published-list feed.
///
/// Throws on network failure, non-2xx status, or malformed JSON. Callers
/// fall back to the on-device list (the hardcoded seed or the last
/// successful fetch) on throw.
public protocol KnownBlossomServersFetcher: Sendable {
    func fetchLatest() async throws -> [BlossomServerEndpoint]
}

/// Wire wrapper for `blossom-servers.json`:
/// `{ "version": 1, "servers": [...] }`.
struct KnownBlossomServersDocument: Codable, Equatable, Sendable {
    let version: Int
    let servers: [BlossomServerEndpoint]
}

enum KnownBlossomServersFetchError: Error, Sendable {
    case badStatus(Int)
    case malformedDocument(Error)
}

/// Production fetcher — plain `URLSession` GET of the GitHub release asset.
public struct GitHubReleasesKnownBlossomServersFetcher: KnownBlossomServersFetcher {
    /// Public only because it is the default argument of the public
    /// initializer (default argument values must be as accessible as
    /// the function they belong to).
    public static let defaultURL = URL(
        string: "https://github.com/onymchat/onym-relayer/releases/latest/download/blossom-servers.json"
    )!

    var url: URL
    var session: URLSession
    var decoder: JSONDecoder

    public init(url: URL = defaultURL, session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    public func fetchLatest() async throws -> [BlossomServerEndpoint] {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw KnownBlossomServersFetchError.badStatus(status)
        }
        // H-3: verify the detached Ed25519 signature at `<url>.sig`.
        // Soft mode by default (see `ContractsTrust`); throws only
        // under enforcement.
        try await SignedAsset.verify(
            assetData: data,
            assetURL: url,
            session: session,
            label: "blossom-servers.json"
        )
        do {
            return try decoder.decode(KnownBlossomServersDocument.self, from: data).servers
        } catch {
            throw KnownBlossomServersFetchError.malformedDocument(error)
        }
    }
}
