import XCTest
@testable import OnymIOS

/// Hits the production fetcher with `StubURLProtocol` (the reusable
/// scaffolding from PR #18) in front. Pins the network behaviour:
/// 200 → parse, non-2xx → throw badStatus, malformed body →
/// throw malformedDocument. Wire-format details are pinned in
/// `ContractsManifestDecodingTests`.
final class ContractsManifestFetcherTests: XCTestCase {
    private var session: URLSession!
    private let fixtureURL = URL(string: "https://test.example/contracts-manifest.json")!

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    func test_fetchLatest_parsesValidDocument() async throws {
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url, self.fixtureURL)
            let body = """
            {
              "version": 1,
              "releases": [{
                "release": "v0.0.1",
                "publishedAt": "2026-05-01T11:43:00Z",
                "contracts": [
                  { "network": "testnet", "type": "anarchy", "id": "CDSIJT...3RQ5B5" }
                ]
              }]
            }
            """
            return (Data(body.utf8), HTTPURLResponse(url: self.fixtureURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesContractsManifestFetcher(url: fixtureURL, session: session)
        let manifest = try await fetcher.fetchLatest()
        XCTAssertEqual(manifest.releases.count, 1)
        XCTAssertEqual(manifest.releases[0].contracts[0].id, "CDSIJT...3RQ5B5")
    }

    func test_fetchLatest_throwsOn404() async {
        StubURLProtocol.set { _ in
            (Data(), HTTPURLResponse(url: self.fixtureURL, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesContractsManifestFetcher(url: fixtureURL, session: session)
        do {
            _ = try await fetcher.fetchLatest()
            XCTFail("expected throw")
        } catch let ContractsManifestFetchError.badStatus(code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("expected badStatus(404), got \(error)")
        }
    }

    func test_fetchLatest_throwsOnMalformedJSON() async {
        StubURLProtocol.set { _ in
            (Data("not json".utf8), HTTPURLResponse(url: self.fixtureURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesContractsManifestFetcher(url: fixtureURL, session: session)
        do {
            _ = try await fetcher.fetchLatest()
            XCTFail("expected throw")
        } catch ContractsManifestFetchError.malformedDocument { /* expected */ }
        catch { XCTFail("expected malformedDocument, got \(error)") }
    }
}
