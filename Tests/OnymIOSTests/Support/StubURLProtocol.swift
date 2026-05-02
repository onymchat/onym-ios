import Foundation

/// `URLProtocol` subclass that intercepts every request issued by a
/// `URLSession` configured with it. Tests register a per-URL handler
/// that returns the bytes / status / headers a fake server would
/// emit. Standard pattern for testing `URLSession`-based code without
/// any third-party HTTP mocking library.
///
/// Usage:
/// ```swift
/// let session = StubURLProtocol.makeSession()
/// StubURLProtocol.set(handler: { request in
///     (Data("hello".utf8), HTTPURLResponse(...))
/// })
/// defer { StubURLProtocol.reset() }
/// // ... use session
/// ```
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    nonisolated(unsafe) private static var handler: Handler?
    private static let lock = NSLock()

    static func set(handler: @escaping Handler) {
        lock.withLock { Self.handler = handler }
    }

    static func reset() {
        lock.withLock { Self.handler = nil }
    }

    /// Build a `URLSession` configured to route every request through
    /// `StubURLProtocol`. Each test should make its own session so
    /// configuration changes don't leak.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
