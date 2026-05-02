import Foundation

/// Network seam that fetches the curated list of known relayers from
/// the latest GitHub Release of `onymchat/onym-relayer`. The repo
/// owner attaches a `relayers.json` asset to each release; the URL
/// `releases/latest/download/<asset>` is a public GitHub redirect
/// that always points at the latest release's asset, so we don't
/// need the GitHub API (and don't burn rate limit).
protocol KnownRelayersFetcher: Sendable {
    /// Fetch and parse the latest `relayers.json`. Throws on network
    /// failure, non-2xx response, or malformed JSON. Callers are
    /// expected to fall back to the cached list on throw.
    func fetchLatest() async throws -> [RelayerEndpoint]
}

/// Production `KnownRelayersFetcher`. Pure `URLSession` — no third-
/// party HTTP client. Tests inject a fake `URLSession` via
/// `URLProtocol` to drive the response without hitting the network.
struct GitHubReleasesKnownRelayersFetcher: KnownRelayersFetcher {
    /// GitHub redirect that always resolves to the latest release's
    /// `relayers.json` asset. See
    /// https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases
    static let defaultURL = URL(string: "https://github.com/onymchat/onym-relayer/releases/latest/download/relayers.json")!

    let url: URL
    let session: URLSession
    let decoder: JSONDecoder

    init(
        url: URL = defaultURL,
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    func fetchLatest() async throws -> [RelayerEndpoint] {
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            throw KnownRelayersFetchError.badStatus(statusCode)
        }
        let document: KnownRelayersDocument
        do {
            document = try decoder.decode(KnownRelayersDocument.self, from: data)
        } catch {
            throw KnownRelayersFetchError.malformedDocument(error)
        }
        return document.relayers
    }
}

enum KnownRelayersFetchError: Error, Sendable {
    case badStatus(Int)
    case malformedDocument(Error)
}
