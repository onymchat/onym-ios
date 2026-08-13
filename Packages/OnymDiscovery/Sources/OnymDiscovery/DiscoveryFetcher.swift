import Foundation

public enum DiscoveryFetchError: Error, Sendable {
    case badStatus(Int)
    /// HTTP 429 — the profile maps this to `rate_limited`.
    case rateLimited
    /// Response body exceeds the profile bound for the document kind.
    case oversize
}

/// Network seam for discovery documents. Returns **bytes**, never
/// parsed values — parsing and verification stay in the repository /
/// trust layer so test fakes stay dumb (same seam discipline as
/// `KnownAuthoritiesFetcher` in OnymModeration). Digests and
/// signatures are over exact served bytes, so nothing between the
/// socket and `DiscoveryTrust` may re-serialize.
public protocol DiscoveryFetching: Sendable {
    /// GET a provider manifest; ≤ 64 KiB.
    func fetchProviderManifest(url: URL) async throws -> Data
    /// GET a catalog snapshot; ≤ 1 MiB.
    func fetchSnapshot(url: URL) async throws -> Data
}

/// Production `DiscoveryFetching`. Plain `URLSession` GETs with the
/// profile's size caps enforced after download (§7).
///
/// Not yet enforced here (tracked for the wiring PR): the §7 redirect
/// rules (≤ 3 redirects, HTTPS-to-HTTPS only, no IP-literal targets)
/// need a session delegate; URLs only ever come from verified
/// documents that already passed the URI rules.
public struct URLSessionDiscoveryFetcher: DiscoveryFetching {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchProviderManifest(url: URL) async throws -> Data {
        try await fetch(url: url, maxBytes: DiscoveryTrust.providerManifestMaxBytes)
    }

    public func fetchSnapshot(url: URL) async throws -> Data {
        try await fetch(url: url, maxBytes: DiscoveryTrust.snapshotMaxBytes)
    }

    private func fetch(url: URL, maxBytes: Int) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status != 429 else { throw DiscoveryFetchError.rateLimited }
        guard (200..<300).contains(status) else {
            throw DiscoveryFetchError.badStatus(status)
        }
        guard data.count <= maxBytes else { throw DiscoveryFetchError.oversize }
        return data
    }
}
