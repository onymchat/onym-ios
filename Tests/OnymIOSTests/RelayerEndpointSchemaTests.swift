import XCTest
@testable import OnymIOS

/// Pin the wire-format compat between the iOS app and the published
/// `relayers.json` (and any saves from earlier app versions). The
/// publisher uses `networks: [String]` so a single deployment can
/// serve multiple Stellar networks; PR #20 / #22 saves used the old
/// singular `network: String` shape. The decoder must accept both.
final class RelayerEndpointSchemaTests: XCTestCase {

    // MARK: - new shape

    func test_decode_pluralNetworksArray_succeeds() throws {
        let json = """
        {
            "name": "Onym Official",
            "url": "https://relayer.onym.chat",
            "networks": ["testnet", "public"]
        }
        """
        let decoded = try JSONDecoder().decode(RelayerEndpoint.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Onym Official")
        XCTAssertEqual(decoded.url, URL(string: "https://relayer.onym.chat"))
        XCTAssertEqual(decoded.networks, ["testnet", "public"])
    }

    func test_decode_pluralNetworks_emptyArray_succeeds() throws {
        let json = """
        { "name": "X", "url": "https://x.com", "networks": [] }
        """
        let decoded = try JSONDecoder().decode(RelayerEndpoint.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.networks, [])
    }

    // MARK: - legacy shape (PR #20 / #22 saved configs)

    func test_decode_legacySingularNetwork_promotesToOneElementArray() throws {
        // PR #20 / #22 wire shape — `network: String`. Decoder
        // promotes to `["X"]` so the in-memory model is uniform.
        let json = """
        {
            "name": "Existing",
            "url": "https://existing.example",
            "network": "testnet"
        }
        """
        let decoded = try JSONDecoder().decode(RelayerEndpoint.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.networks, ["testnet"])
    }

    func test_decode_legacySingularNetwork_customSentinel_promotesToOneElementArray() throws {
        // Custom user-typed entries from PR #20 / #22 used `network: "custom"`.
        let json = """
        {
            "name": "my-relayer.dev",
            "url": "https://my-relayer.dev",
            "network": "custom"
        }
        """
        let decoded = try JSONDecoder().decode(RelayerEndpoint.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.networks, [RelayerEndpoint.customNetwork])
    }

    // MARK: - encoder

    func test_encode_alwaysEmitsPluralShape() throws {
        let endpoint = RelayerEndpoint(
            name: "X",
            url: URL(string: "https://x.com")!,
            networks: ["testnet"]
        )
        let json = try JSONEncoder().encode(endpoint)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNotNil(dict["networks"], "encoder must emit `networks` array")
        XCTAssertNil(dict["network"], "encoder must NOT emit the legacy singular `network`")
    }

    func test_roundtrip_throughEncoderAndDecoder() throws {
        let original = RelayerEndpoint(
            name: "Onym Official",
            url: URL(string: "https://relayer.onym.chat")!,
            networks: ["testnet", "public"]
        )
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RelayerEndpoint.self, from: json)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - factory

    func test_customFactory_marksNetworkAsCustom() {
        let endpoint = RelayerEndpoint.custom(url: URL(string: "https://x.com")!)
        XCTAssertEqual(endpoint.networks, [RelayerEndpoint.customNetwork])
        XCTAssertEqual(endpoint.name, "x.com",
                       "custom endpoint name defaults to the URL host")
    }

    // MARK: - manifest decoding (current published shape)

    func test_decode_publishedManifestShape_succeeds() throws {
        // Snapshot of what
        // https://github.com/onymchat/onym-relayer/releases/latest/download/relayers.json
        // is currently serving. Pin so the iOS app stays
        // schema-compatible with future publisher releases.
        let json = """
        {
            "version": 1,
            "relayers": [
                {
                    "name": "Onym Official",
                    "url": "https://relayer.onym.chat",
                    "networks": ["testnet", "public"]
                }
            ]
        }
        """
        let document = try JSONDecoder().decode(KnownRelayersDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(document.relayers.count, 1)
        XCTAssertEqual(document.relayers[0].networks, ["testnet", "public"])
    }
}
