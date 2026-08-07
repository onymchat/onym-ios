import Foundation
import OnymFoundation

/// Fetches the Onym-published default Nostr-relay list from a GitHub
/// release asset. Mirrors `KnownRelayersFetcher` (the chain relayer's
/// published-list feed): the `releases/latest/download/<asset>` redirect
/// needs no GitHub API, auth, or rate limit — publishing a new release
/// with the same filename is the whole deploy story.
///
/// Throws on network failure, non-2xx status, or malformed JSON. Callers
/// fall back to the on-device list (the hardcoded seed or the last
/// successful fetch) on throw.
public protocol KnownNostrRelaysFetcher: Sendable {
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
public struct GitHubReleasesKnownNostrRelaysFetcher: KnownNostrRelaysFetcher {
    static let defaultURL = URL(
        string: "https://github.com/onymchat/onym-relayer/releases/latest/download/nostr-relays.json"
    )!

    var url: URL
    var session: URLSession
    var decoder: JSONDecoder

    /// Production configuration — GitHub release URL, shared session.
    /// The only shape consumers outside the package need; the
    /// parameterized initializer below stays internal for tests.
    public init() {
        self.init(url: Self.defaultURL)
    }

    init(url: URL = defaultURL, session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    public func fetchLatest() async throws -> [NostrRelayEndpoint] {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw KnownNostrRelaysFetchError.badStatus(status)
        }
        // H-3: verify the detached Ed25519 signature at `<url>.sig`.
        // Soft mode by default (see `ContractsTrust`); throws only
        // under enforcement.
        try await SignedAsset.verify(
            assetData: data,
            assetURL: url,
            session: session,
            label: "nostr-relays.json"
        )
        do {
            return try decoder.decode(KnownNostrRelaysDocument.self, from: data).relays
        } catch {
            throw KnownNostrRelaysFetchError.malformedDocument(error)
        }
    }
}
