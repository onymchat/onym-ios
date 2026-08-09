import Foundation
import OnymFoundation

/// One entry in the interface's published authority directory. The
/// directory pins each authority's operator public key out-of-band
/// from its manifest: a MITM that swaps the hosted manifest can't also
/// swap the key it must verify against.
public struct AuthorityListing: Codable, Sendable, Equatable {
    /// `onym:component:<authority-id>`.
    public let componentId: String
    /// Human-readable name shown in the picker.
    public let name: String
    public let manifestURL: URL
    /// Base URL of the Authority HTTP API. Optional for compatibility
    /// with directories published before the operation surface existed;
    /// those entries resolve the API beside `manifestURL`.
    public let apiBaseURL: URL?
    /// The authority's Ed25519 operator public key, base64 raw bytes.
    public let operatorPublicKeyBase64: String

    public init(
        componentId: String,
        name: String,
        manifestURL: URL,
        apiBaseURL: URL? = nil,
        operatorPublicKeyBase64: String
    ) {
        self.componentId = componentId
        self.name = name
        self.manifestURL = manifestURL
        self.apiBaseURL = apiBaseURL
        self.operatorPublicKeyBase64 = operatorPublicKeyBase64
    }

    /// The reference implementation serves `/manifest.json` and `/v1/*`
    /// from one base. New directory entries should publish `apiBaseURL`
    /// explicitly; the fallback keeps already-published entries usable.
    public var resolvedAPIBaseURL: URL {
        apiBaseURL ?? manifestURL.deletingLastPathComponent()
    }
}

struct KnownAuthoritiesDocument: Codable {
    let authorities: [AuthorityListing]
}

/// Network seam that fetches the curated list of moderation
/// authorities this interface designates. Same shape and trust story
/// as `KnownRelayersFetcher` in OnymChain: a GitHub latest-release
/// asset with an optional detached `.sig`, soft-verified until the
/// release-signing pipeline is live.
public protocol KnownAuthoritiesFetcher: Sendable {
    /// Fetch and parse the latest `authorities.json`. Throws on
    /// network failure, non-2xx, or malformed JSON; callers fall back
    /// to the cached list.
    func fetchLatest() async throws -> [AuthorityListing]
}

/// Production `KnownAuthoritiesFetcher`. Pure `URLSession`; tests
/// inject a fake session via `URLProtocol`.
public struct GitHubReleasesKnownAuthoritiesFetcher: KnownAuthoritiesFetcher {
    /// GitHub redirect that always resolves to the latest release's
    /// `authorities.json` asset.
    public static let defaultURL = URL(string: "https://github.com/onymchat/onym-authorities/releases/latest/download/authorities.json")!

    let url: URL
    let session: URLSession
    let decoder: JSONDecoder

    public init(
        url: URL = defaultURL,
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.url = url
        self.session = session
        self.decoder = decoder
    }

    public func fetchLatest() async throws -> [AuthorityListing] {
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            throw KnownAuthoritiesFetchError.badStatus(statusCode)
        }
        try await SignedAsset.verify(
            assetData: data,
            assetURL: url,
            session: session,
            label: "authorities.json"
        )
        let document: KnownAuthoritiesDocument
        do {
            document = try decoder.decode(KnownAuthoritiesDocument.self, from: data)
        } catch {
            throw KnownAuthoritiesFetchError.malformedDocument(error)
        }
        return document.authorities
    }
}

public enum KnownAuthoritiesFetchError: Error, Sendable {
    case badStatus(Int)
    case malformedDocument(Error)
}
