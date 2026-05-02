import XCTest
@testable import OnymIOS

/// Hits the production `URLSession`-backed fetcher with `StubURLProtocol`
/// in front so we can pin the wire format (the `relayers.json` shape we
/// promise to publish) and the error-path behaviour (cache fallback
/// happens at the repository layer; the fetcher itself just throws on
/// any failure).
final class KnownRelayersFetcherTests: XCTestCase {
    private var session: URLSession!
    private let fixtureURL = URL(string: "https://test.example/relayers.json")!

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - happy path

    func test_fetchLatest_parsesValidDocument() async throws {
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url, self.fixtureURL)
            let body = """
            {
                "version": 1,
                "relayers": [
                    { "name": "Onym Testnet", "url": "https://relayer-testnet.onym.chat", "network": "testnet" },
                    { "name": "Onym Mainnet", "url": "https://relayer.onym.chat", "network": "public" }
                ]
            }
            """
            return (Data(body.utf8), HTTPURLResponse(url: self.fixtureURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesKnownRelayersFetcher(url: fixtureURL, session: session)

        let list = try await fetcher.fetchLatest()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "Onym Testnet")
        XCTAssertEqual(list[0].url, URL(string: "https://relayer-testnet.onym.chat"))
        XCTAssertEqual(list[0].network, "testnet")
        XCTAssertEqual(list[1].network, "public")
    }

    func test_fetchLatest_acceptsEmptyRelayersArray() async throws {
        // Bootstrap state — release exists but no relayers published yet.
        StubURLProtocol.set { _ in
            let body = #"{ "version": 1, "relayers": [] }"#
            return (Data(body.utf8), HTTPURLResponse(url: self.fixtureURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesKnownRelayersFetcher(url: fixtureURL, session: session)
        let list = try await fetcher.fetchLatest()
        XCTAssertEqual(list, [])
    }

    // MARK: - error paths

    func test_fetchLatest_throwsOn404() async {
        StubURLProtocol.set { _ in
            (Data(), HTTPURLResponse(url: self.fixtureURL, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesKnownRelayersFetcher(url: fixtureURL, session: session)
        do {
            _ = try await fetcher.fetchLatest()
            XCTFail("expected throw")
        } catch let KnownRelayersFetchError.badStatus(code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("expected badStatus(404), got \(error)")
        }
    }

    func test_fetchLatest_throwsOn500() async {
        StubURLProtocol.set { _ in
            (Data(), HTTPURLResponse(url: self.fixtureURL, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesKnownRelayersFetcher(url: fixtureURL, session: session)
        do {
            _ = try await fetcher.fetchLatest()
            XCTFail("expected throw")
        } catch KnownRelayersFetchError.badStatus { /* ok */ }
        catch { XCTFail("expected badStatus, got \(error)") }
    }

    func test_fetchLatest_throwsOnMalformedJSON() async {
        StubURLProtocol.set { _ in
            let body = "not even json"
            return (Data(body.utf8), HTTPURLResponse(url: self.fixtureURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesKnownRelayersFetcher(url: fixtureURL, session: session)
        do {
            _ = try await fetcher.fetchLatest()
            XCTFail("expected throw")
        } catch KnownRelayersFetchError.malformedDocument { /* ok */ }
        catch { XCTFail("expected malformedDocument, got \(error)") }
    }

    func test_fetchLatest_throwsOnMissingRelayersField() async {
        StubURLProtocol.set { _ in
            // valid JSON but wrong shape
            let body = #"{ "version": 1, "something_else": [] }"#
            return (Data(body.utf8), HTTPURLResponse(url: self.fixtureURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesKnownRelayersFetcher(url: fixtureURL, session: session)
        do {
            _ = try await fetcher.fetchLatest()
            XCTFail("expected throw")
        } catch KnownRelayersFetchError.malformedDocument { /* ok */ }
        catch { XCTFail("expected malformedDocument, got \(error)") }
    }

    // MARK: - default URL

    func test_defaultURL_pointsAtGitHubReleasesLatestDownload() {
        XCTAssertEqual(
            GitHubReleasesKnownRelayersFetcher.defaultURL.absoluteString,
            "https://github.com/onymchat/onym-relayer/releases/latest/download/relayers.json",
            "Renaming this URL silently breaks the prepopulation flow on every install"
        )
    }
}
