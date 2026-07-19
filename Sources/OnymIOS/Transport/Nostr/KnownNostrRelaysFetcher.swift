import Foundation

/// Fetches the Onym-published default Nostr-relay list from a GitHub
/// release asset. Mirrors `KnownRelayersFetcher` (the chain relayer's
/// published-list feed): the `releases/latest/download/<asset>` redirect
/// needs no GitHub API, auth, or rate limit — publishing a new release
/// with the same filename is the whole deploy story.
///
/// Throws on network failure, non-2xx status, or malformed JSON. Callers
/// fall back to the on-device list (the hardcoded seed or the last
/// successful fetch) on throw.
protocol KnownNostrRelaysFetcher: Sendable {
    func fetchLatest() async throws -> [NostrRelayEndpoint]
}

/// Wire wrapper for `nostr-relays.json`: `{ "version": 1, "relays": [...] }`.
/// `version` is a forward-compat routing hint; `fetchLatest` returns
/// `.relays`.
struct KnownNostrRelaysDocument: Codable, Equatable, Sendable {
    let version: Int
    let relays: [NostrRelayEndpoint]
}

enum KnownNostrRelaysFetchError: Error, Sendable {
    case badStatus(Int)
    case malformedDocument(Error)
}

/// Production fetcher — plain `URLSession` GET of the GitHub release asset.
struct GitHubReleasesKnownNostrRelaysFetcher: KnownNostrRelaysFetcher {
    static let defaultURL = URL(
        string: "https://github.com/onymchat/onym-relayer/releases/latest/download/nostr-relays.json"
    )!

    var url: URL
    var session: URLSession
    var decoder: JSONDecoder

    init(url: URL = defaultURL, session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    func fetchLatest() async throws -> [NostrRelayEndpoint] {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw KnownNostrRelaysFetchError.badStatus(status)
        }
        do {
            return try decoder.decode(KnownNostrRelaysDocument.self, from: data).relays
        } catch {
            throw KnownNostrRelaysFetchError.malformedDocument(error)
        }
    }
}
