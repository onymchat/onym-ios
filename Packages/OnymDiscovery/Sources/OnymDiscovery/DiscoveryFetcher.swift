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
/// profile's §7 bounds: size caps enforced **while streaming** (the
/// transfer is aborted as soon as the body crosses the bound, so an
/// oversized or endless response is never fully buffered), a 60 s
/// per-request timeout, and a redirect policy of at most 3 redirects,
/// HTTPS-to-HTTPS only, refusing IP-literal (and other URI-rule
/// violating) targets. A refused redirect stops the chain, so the
/// request completes with the 3xx status and fails as `badStatus`.
public struct URLSessionDiscoveryFetcher: DiscoveryFetching {
    /// §7: fetch timeout ≤ 60 s per request.
    static let requestTimeoutSeconds: TimeInterval = 60

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
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeoutSeconds
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: RedirectPolicy()
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status != 429 else { throw DiscoveryFetchError.rateLimited }
        guard (200..<300).contains(status) else {
            throw DiscoveryFetchError.badStatus(status)
        }
        // A declared oversize body is refused before reading a byte;
        // an undeclared (or lying) one is cut off at the cap below —
        // throwing out of the iteration cancels the transfer.
        if response.expectedContentLength > Int64(maxBytes) {
            throw DiscoveryFetchError.oversize
        }
        var data = Data()
        data.reserveCapacity(min(
            maxBytes,
            response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 0
        ))
        for try await byte in bytes {
            guard data.count < maxBytes else { throw DiscoveryFetchError.oversize }
            data.append(byte)
        }
        return data
    }

    /// §7 redirect rules: ≤ 3 redirects per fetch, HTTPS-to-HTTPS
    /// only, and never toward an IP literal. Returning `nil` refuses
    /// the redirect (the task then completes with the 3xx response).
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        private var redirects = 0

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            redirects += 1
            guard redirects <= 3 else { return nil }
            guard let target = request.url,
                  target.scheme?.lowercased() == "https",
                  let host = target.host(), !Self.isIPLiteral(host)
            else { return nil }
            return request
        }

        private static func isIPLiteral(_ host: String) -> Bool {
            if host.contains(":") { return true } // IPv6 (bracket-stripped)
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return true // dotted-decimal or integer form
            }
            if let last = parts.last, last.lowercased().hasPrefix("0x") {
                return true // hex form
            }
            return false
        }
    }
}
