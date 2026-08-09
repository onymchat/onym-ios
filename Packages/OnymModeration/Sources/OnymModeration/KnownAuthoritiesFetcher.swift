import Foundation
import OnymFoundation
import os.log

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
    /// Base URL of the Authority HTTP API, explicitly designated by the
    /// Interface's directory. It is never inferred from `manifestURL`:
    /// manifests may be safely mirrored because their bytes are signed,
    /// while this endpoint receives the user's signed mandate.
    public let apiBaseURL: URL
    /// The authority's Ed25519 operator public key, base64 raw bytes.
    public let operatorPublicKeyBase64: String

    public init(
        componentId: String,
        name: String,
        manifestURL: URL,
        apiBaseURL: URL,
        operatorPublicKeyBase64: String
    ) {
        self.componentId = componentId
        self.name = name
        self.manifestURL = manifestURL
        self.apiBaseURL = apiBaseURL
        self.operatorPublicKeyBase64 = operatorPublicKeyBase64
    }
}

private struct LossyAuthorityListing: Decodable {
    private static let log = Logger(
        subsystem: "app.onym.ios",
        category: "ModerationDirectory"
    )

    let value: AuthorityListing?

    init(from decoder: Decoder) throws {
        do {
            let listing = try AuthorityListing(from: decoder)
            guard listing.apiBaseURL.scheme?.lowercased() == "https",
                  listing.apiBaseURL.host != nil
            else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Authority apiBaseURL must use HTTPS"
                    )
                )
            }
            value = listing
        } catch {
            let componentId = (try? decoder.container(keyedBy: DiagnosticKeys.self))
                .flatMap { try? $0.decodeIfPresent(String.self, forKey: .componentId) }
                ?? "<unknown>"
            Self.log.error(
                "Skipping malformed Authority \(componentId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            value = nil
        }
    }

    private enum DiagnosticKeys: String, CodingKey {
        case componentId
    }
}

struct KnownAuthoritiesDocument: Decodable {
    let authorities: [AuthorityListing]

    private enum CodingKeys: String, CodingKey {
        case authorities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([LossyAuthorityListing].self, forKey: .authorities)
        authorities = decoded.compactMap(\.value)
        guard !authorities.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .authorities,
                in: container,
                debugDescription: "directory contains no valid Authority entries"
            )
        }
    }
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
