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
        let handler = CappedFetchHandler(maxBytes: maxBytes)
        let task = session.dataTask(with: request)
        task.delegate = handler
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handler.begin(continuation: continuation, task: task)
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Delegate-driven capped download: the body accumulates in the
    /// chunks the URL-loading system delivers (never byte-per-iteration
    /// — `AsyncBytes` iteration is pathologically slow at the 1 MiB
    /// snapshot cap), the declared-length refusal fires before a body
    /// byte is read, and the mid-stream cap cancels the transfer the
    /// moment the accumulated body would cross the bound. Also carries
    /// the §7 redirect rules: ≤ 3 redirects per fetch, HTTPS-to-HTTPS
    /// only, and never toward an IP literal — a refused redirect stops
    /// the chain, so the request completes with the 3xx status and
    /// fails as `badStatus`.
    private final class CappedFetchHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        /// Touched only on the session's serial delegate queue.
        private var body = Data()
        private var redirects = 0

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func begin(continuation: CheckedContinuation<Data, Error>, task: URLSessionDataTask) {
            lock.withLock { self.continuation = continuation }
            task.resume()
        }

        /// Resume-once: whichever outcome lands first (status refusal,
        /// oversize, completion, cancellation) wins; the rest no-op.
        private func finish(_ result: Result<Data, Error>, cancelling task: URLSessionTask? = nil) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            task?.cancel()
            continuation?.resume(with: result)
        }

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

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse
        ) async -> URLSession.ResponseDisposition {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status != 429 else {
                finish(.failure(DiscoveryFetchError.rateLimited))
                return .cancel
            }
            guard (200..<300).contains(status) else {
                finish(.failure(DiscoveryFetchError.badStatus(status)))
                return .cancel
            }
            // A declared oversize body is refused before reading a byte.
            guard response.expectedContentLength <= Int64(maxBytes) else {
                finish(.failure(DiscoveryFetchError.oversize))
                return .cancel
            }
            body.reserveCapacity(min(
                maxBytes,
                response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 0
            ))
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Mid-stream cap: an undeclared (or lying) oversize body is
            // cut off on the chunk that crosses the bound, never fully
            // buffered.
            guard body.count + data.count <= maxBytes else {
                finish(.failure(DiscoveryFetchError.oversize), cancelling: dataTask)
                return
            }
            body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(error))
            } else {
                finish(.success(body))
            }
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
