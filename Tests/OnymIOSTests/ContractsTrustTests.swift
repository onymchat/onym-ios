import XCTest
import CryptoKit
@testable import OnymIOS

/// H-3 — client-side Ed25519 detached-signature verification for the
/// trust-critical fetched assets. Covers the pure verifier, the shared
/// `SignedAsset.verify` policy (soft vs. enforce), and the soft-mode
/// behaviour through the real manifest fetcher.
final class ContractsTrustTests: XCTestCase {
    private var session: URLSession!
    private let assetURL = URL(string: "https://test.example/contracts-manifest.json")!

    override func setUp() {
        super.setUp()
        session = StubURLProtocol.makeSession()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - Ed25519DetachedSignatureVerifier

    func test_verifier_validSignatureVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("trust-critical payload".utf8)
        let sig = try key.signature(for: data)
        let verifier = Ed25519DetachedSignatureVerifier(publicKey: key.publicKey)
        XCTAssertTrue(verifier.isValid(signature: sig, for: data))
    }

    func test_verifier_tamperedBytesFail() throws {
        let key = Curve25519.Signing.PrivateKey()
        let sig = try key.signature(for: Data("original".utf8))
        let verifier = Ed25519DetachedSignatureVerifier(publicKey: key.publicKey)
        XCTAssertFalse(verifier.isValid(signature: sig, for: Data("tampered".utf8)))
    }

    func test_verifier_wrongKeyFails() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let data = Data("payload".utf8)
        let sig = try signingKey.signature(for: data)
        let verifier = Ed25519DetachedSignatureVerifier(publicKey: otherKey.publicKey)
        XCTAssertFalse(verifier.isValid(signature: sig, for: data))
    }

    func test_verifier_noKeyFailsClosed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("payload".utf8)
        let sig = try key.signature(for: data)
        let verifier = Ed25519DetachedSignatureVerifier(publicKey: nil)
        XCTAssertFalse(verifier.isValid(signature: sig, for: data))
    }

    // MARK: - SignedAsset.verify — enforce mode

    func test_verify_enforce_validSignaturePasses() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("asset-bytes".utf8)
        let sig = try key.signature(for: data)
        StubURLProtocol.set { request in
            XCTAssertEqual(request.url?.absoluteString, self.assetURL.absoluteString + ".sig")
            return (sig, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await SignedAsset.verify(
            assetData: data,
            assetURL: assetURL,
            session: session,
            label: "test",
            verifier: Ed25519DetachedSignatureVerifier(publicKey: key.publicKey),
            enforce: true
        )
    }

    func test_verify_enforce_invalidSignatureThrows() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("asset-bytes".utf8)
        let sig = try key.signature(for: Data("something-else".utf8))
        StubURLProtocol.set { request in
            (sig, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            try await SignedAsset.verify(
                assetData: data, assetURL: assetURL, session: session, label: "test",
                verifier: Ed25519DetachedSignatureVerifier(publicKey: key.publicKey), enforce: true
            )
            XCTFail("expected throw")
        } catch SignedAssetVerificationError.signatureInvalid { /* expected */ }
        catch { XCTFail("expected signatureInvalid, got \(error)") }
    }

    func test_verify_enforce_missingSignatureThrows() async {
        let data = Data("asset-bytes".utf8)
        StubURLProtocol.set { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        do {
            try await SignedAsset.verify(
                assetData: data, assetURL: assetURL, session: session, label: "test",
                verifier: Ed25519DetachedSignatureVerifier(publicKey: Curve25519.Signing.PrivateKey().publicKey), enforce: true
            )
            XCTFail("expected throw")
        } catch SignedAssetVerificationError.signatureUnavailable { /* expected */ }
        catch { XCTFail("expected signatureUnavailable, got \(error)") }
    }

    // MARK: - SignedAsset.verify — soft mode (default) never throws

    func test_verify_softMode_missingSignatureDoesNotThrow() async throws {
        let data = Data("asset-bytes".utf8)
        StubURLProtocol.set { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        try await SignedAsset.verify(
            assetData: data, assetURL: assetURL, session: session, label: "test",
            verifier: .bundled, enforce: false
        )
    }

    func test_verify_softMode_invalidSignatureDoesNotThrow() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("asset-bytes".utf8)
        let sig = try key.signature(for: Data("something-else".utf8))
        StubURLProtocol.set { request in
            (sig, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await SignedAsset.verify(
            assetData: data, assetURL: assetURL, session: session, label: "test",
            verifier: Ed25519DetachedSignatureVerifier(publicKey: key.publicKey), enforce: false
        )
    }

    // MARK: - Soft mode through the real fetcher still yields the manifest

    func test_manifestFetcher_softMode_invalidSignatureStillDecodes() async throws {
        let manifestBody = """
        {
          "version": 1,
          "releases": [{
            "release": "v0.0.1",
            "publishedAt": "2026-05-01T11:43:00Z",
            "contracts": [{ "network": "testnet", "type": "anarchy", "id": "CID" }]
          }]
        }
        """
        StubURLProtocol.set { request in
            if request.url?.absoluteString.hasSuffix(".sig") == true {
                // A signature is present but does not verify — soft mode
                // (enforcement OFF) must log and still return the manifest.
                return (Data("bogus-signature".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(manifestBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let fetcher = GitHubReleasesContractsManifestFetcher(url: assetURL, session: session)
        let manifest = try await fetcher.fetchLatest()
        XCTAssertEqual(manifest.releases.first?.contracts.first?.id, "CID")
    }

    // MARK: - signature decoding + default policy

    func test_decodeSignature_acceptsRawAndBase64() throws {
        let key = Curve25519.Signing.PrivateKey()
        let sig = try key.signature(for: Data("x".utf8))
        XCTAssertEqual(sig.count, 64)
        XCTAssertEqual(SignedAsset.decodeSignature(sig), sig, "raw 64-byte signature used as-is")
        let base64Body = Data(sig.base64EncodedString().utf8)
        XCTAssertEqual(SignedAsset.decodeSignature(base64Body), sig, "base64 text decoded to raw bytes")
    }

    func test_enforcementDefaultsOff() {
        XCTAssertFalse(
            ContractsTrust.enforceSignatures,
            "H-3: enforcement must stay OFF until the release-signing pipeline ships signed assets and a real public key"
        )
    }
}
