import Foundation

/// Network seam: fetches the curated `contracts-manifest.json` asset
/// from the latest release of `onymchat/onym-contracts`. Same redirect
/// pattern as `KnownRelayersFetcher` from PR #18 — the URL
/// `releases/latest/download/<asset>` is a public GitHub redirect that
/// always points at the latest release, no GitHub API rate limit.
///
/// Unknown enum values (a future `network` or `type` an older client
/// doesn't know about) are silently dropped at parse time so the rest
/// of the manifest stays usable.
protocol ContractsManifestFetcher: Sendable {
    func fetchLatest() async throws -> ContractsManifest
}

/// Production `ContractsManifestFetcher`. Pure `URLSession` — no
/// third-party HTTP client. Tests inject a fake `URLSession` via
/// `StubURLProtocol` to drive the response without hitting the network.
struct GitHubReleasesContractsManifestFetcher: ContractsManifestFetcher {
    /// GitHub redirect that always resolves to the latest release's
    /// `contracts-manifest.json` asset.
    static let defaultURL = URL(string: "https://github.com/onymchat/onym-contracts/releases/latest/download/contracts-manifest.json")!

    let url: URL
    let session: URLSession

    init(url: URL = defaultURL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    func fetchLatest() async throws -> ContractsManifest {
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            throw ContractsManifestFetchError.badStatus(statusCode)
        }
        return try Self.decodeFiltering(data)
    }

    /// Decode the manifest, dropping any `ContractEntry` whose
    /// `network` or `type` doesn't match a known enum value. Visible
    /// at `internal` access so the same filtering can be tested
    /// without going through the URL pipeline.
    static func decodeFiltering(_ data: Data) throws -> ContractsManifest {
        let raw: RawManifest
        do {
            raw = try JSONDecoder.iso8601().decode(RawManifest.self, from: data)
        } catch {
            throw ContractsManifestFetchError.malformedDocument(error)
        }
        let releases = raw.releases.map { rawRelease -> ContractRelease in
            let contracts = rawRelease.contracts.compactMap { rawEntry -> ContractEntry? in
                guard let network = ContractNetwork(rawValue: rawEntry.network),
                      let type = GovernanceType(rawValue: rawEntry.type)
                else { return nil }
                return ContractEntry(network: network, type: type, id: rawEntry.id)
            }
            return ContractRelease(
                release: rawRelease.release,
                publishedAt: rawRelease.publishedAt,
                contracts: contracts
            )
        }
        return ContractsManifest(version: raw.version, releases: releases)
    }
}

/// Stringly-typed mirror of the wire format. Decoded first, then
/// projected onto the typed `ContractsManifest` while filtering
/// unknown `network` / `type` values. The two-step shape keeps the
/// public types strict while the wire format stays forward-compatible.
private struct RawManifest: Decodable {
    let version: Int
    let releases: [RawRelease]

    struct RawRelease: Decodable {
        let release: String
        let publishedAt: Date
        let contracts: [RawEntry]
    }

    struct RawEntry: Decodable {
        let network: String
        let type: String
        let id: String
    }
}

enum ContractsManifestFetchError: Error, Sendable {
    case badStatus(Int)
    case malformedDocument(Error)
}
