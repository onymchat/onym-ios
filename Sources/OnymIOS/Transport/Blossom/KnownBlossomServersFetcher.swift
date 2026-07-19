import Foundation

/// Fetches the Onym-published default Blossom-server list from a GitHub
/// release asset. Mirrors `KnownNostrRelaysFetcher` / the chain relayer's
/// published-list feed.
///
/// Throws on network failure, non-2xx status, or malformed JSON. Callers
/// fall back to the on-device list (the hardcoded seed or the last
/// successful fetch) on throw.
protocol KnownBlossomServersFetcher: Sendable {
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
struct GitHubReleasesKnownBlossomServersFetcher: KnownBlossomServersFetcher {
    static let defaultURL = URL(
        string: "https://github.com/onymchat/onym-relayer/releases/latest/download/blossom-servers.json"
    )!

    var url: URL
    var session: URLSession
    var decoder: JSONDecoder

    init(url: URL = defaultURL, session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    func fetchLatest() async throws -> [BlossomServerEndpoint] {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw KnownBlossomServersFetchError.badStatus(status)
        }
        do {
            return try decoder.decode(KnownBlossomServersDocument.self, from: data).servers
        } catch {
            throw KnownBlossomServersFetchError.malformedDocument(error)
        }
    }
}
