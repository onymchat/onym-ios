import Foundation
import XCTest
@testable import OnymDiscovery

/// In-process HTTP stub: serves canned (status, headers, body) per URL
/// through the URL-loading system, so `URLSessionDiscoveryFetcher`'s
/// real streaming path is exercised without a network.
private final class StubURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: Response] = [:]

    static func set(_ response: Response, for url: URL) {
        lock.withLock { responses[url] = response }
    }

    static func reset() {
        lock.withLock { responses = [:] }
    }

    private static func response(for url: URL?) -> Response? {
        lock.withLock { url.flatMap { responses[$0] } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let stub = Self.response(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Chunked delivery so the fetcher's cap check runs mid-stream,
        // not on one complete buffer.
        let chunkSize = 16 * 1024
        var offset = 0
        while offset < stub.body.count {
            let end = min(offset + chunkSize, stub.body.count)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DiscoveryFetcherTests: XCTestCase {
    private let url = URL(string: "https://stub.example/manifest.json")!

    private func makeFetcher() -> URLSessionDiscoveryFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionDiscoveryFetcher(session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testBodyAtTheCapIsReturnedWhole() async throws {
        let body = Data(repeating: 0x61, count: DiscoveryTrust.providerManifestMaxBytes)
        StubURLProtocol.set(.init(status: 200, headers: [:], body: body), for: url)

        let fetched = try await makeFetcher().fetchProviderManifest(url: url)
        XCTAssertEqual(fetched, body)
    }

    func testSnapshotAtTheFullMebibyteCapStreamsWholeAndFast() async throws {
        // Throughput-shaped: a snapshot at the full 1 MiB bound must
        // come back intact via chunked accumulation (the old
        // byte-per-iteration loop was pathologically slow exactly here).
        var body = Data(capacity: DiscoveryTrust.snapshotMaxBytes)
        while body.count < DiscoveryTrust.snapshotMaxBytes {
            body.append(UInt8.random(in: .min ... .max))
        }
        StubURLProtocol.set(.init(status: 200, headers: [:], body: body), for: url)

        let started = Date()
        let fetched = try await makeFetcher().fetchSnapshot(url: url)
        XCTAssertEqual(fetched, body)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 5,
            "a 1 MiB in-process fetch finishing this slowly means byte-wise accumulation is back"
        )
    }

    func testUndeclaredOversizeBodyIsAbortedAtTheCap() async {
        // No Content-Length header: the declared-length check cannot
        // fire, so this exercises the mid-stream abort — the §7 cap
        // must hold without buffering the full response.
        let body = Data(repeating: 0x61, count: DiscoveryTrust.providerManifestMaxBytes + 1)
        StubURLProtocol.set(.init(status: 200, headers: [:], body: body), for: url)

        do {
            _ = try await makeFetcher().fetchProviderManifest(url: url)
            XCTFail("expected oversize")
        } catch DiscoveryFetchError.oversize {
        } catch {
            XCTFail("expected oversize, got \(error)")
        }
    }

    func testDeclaredOversizeBodyIsRefusedUpFront() async {
        let body = Data(repeating: 0x61, count: DiscoveryTrust.providerManifestMaxBytes + 1)
        StubURLProtocol.set(
            .init(status: 200, headers: ["Content-Length": String(body.count)], body: body),
            for: url
        )

        do {
            _ = try await makeFetcher().fetchProviderManifest(url: url)
            XCTFail("expected oversize")
        } catch DiscoveryFetchError.oversize {
        } catch {
            XCTFail("expected oversize, got \(error)")
        }
    }

    func testStatus429MapsToRateLimited() async {
        StubURLProtocol.set(.init(status: 429, headers: [:], body: Data()), for: url)

        do {
            _ = try await makeFetcher().fetchProviderManifest(url: url)
            XCTFail("expected rateLimited")
        } catch DiscoveryFetchError.rateLimited {
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    func testNonSuccessStatusMapsToBadStatus() async {
        StubURLProtocol.set(.init(status: 503, headers: [:], body: Data()), for: url)

        do {
            _ = try await makeFetcher().fetchSnapshot(url: url)
            XCTFail("expected badStatus")
        } catch DiscoveryFetchError.badStatus(503) {
        } catch {
            XCTFail("expected badStatus(503), got \(error)")
        }
    }
}
