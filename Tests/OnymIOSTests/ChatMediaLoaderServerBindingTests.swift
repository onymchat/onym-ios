import Foundation
import XCTest
@testable import OnymIOS
import OnymChatsCore
import OnymTransportBlossom

/// The read half of the server-stamp contract: all three media loaders
/// download a stamped attachment through a client BOUND to the
/// attachment's `server` — but ONLY when that server is one of the
/// user's configured endpoints. The stamp arrives off the wire, so an
/// unrecognized stamp (a peer-chosen host) must NEVER receive a
/// request: it falls back to the live client, as do legacy nil-server
/// rows and loaders with no allowlist wired.
final class ChatMediaLoaderServerBindingTests: XCTestCase {
    private static let stampedServer = "https://stamped.example"

    // MARK: - Image loader

    func test_imageLoader_stampedAttachment_downloadsViaBoundClient() async throws {
        let sealed = try ChatImageCrypto.seal(Data("image-bytes".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: Self.stampedServer)!] }
        )

        let plaintext = try await loader.plaintext(
            for: Self.imageAttachment(sealed: sealed, server: Self.stampedServer)
        )

        XCTAssertEqual(plaintext, Data("image-bytes".utf8))
        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: Self.stampedServer, sha256: sealed.sha256Hex)],
                       "a stamped attachment must fetch through the bound client")
    }

    func test_imageLoader_legacyNilServer_downloadsViaLiveClient() async throws {
        let sealed = try ChatImageCrypto.seal(Data("legacy-bytes".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(blossomClient: client, cacheDirectory: Self.tempDir())

        _ = try await loader.plaintext(
            for: Self.imageAttachment(sealed: sealed, server: nil)
        )

        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: nil, sha256: sealed.sha256Hex)],
                       "no stamp → the live (unbound) client")
    }

    func test_imageLoader_stampNotInConfiguredSet_usesLiveClient_neverContactsStamp() async throws {
        // The security property: a peer-chosen stamp outside the
        // user's configured servers must not receive ANY request —
        // the download goes through the live client instead.
        let sealed = try ChatImageCrypto.seal(Data("hostile-stamp".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: "https://mine.example")!] }
        )

        _ = try await loader.plaintext(
            for: Self.imageAttachment(sealed: sealed, server: "https://tracker.example")
        )

        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: nil, sha256: sealed.sha256Hex)],
                       "an unconfigured stamp must fall back to the live client, with zero requests bound to the stamp")
    }

    func test_imageLoader_noAllowlistWired_ignoresStamp() async throws {
        // Default (empty) allowlist — e.g. a composition root that
        // never wires the provider — must ignore every stamp.
        let sealed = try ChatImageCrypto.seal(Data("unwired".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(blossomClient: client, cacheDirectory: Self.tempDir())

        _ = try await loader.plaintext(
            for: Self.imageAttachment(sealed: sealed, server: Self.stampedServer)
        )

        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: nil, sha256: sealed.sha256Hex)])
    }

    func test_stampMatchingIsByNormalizedOrigin() async throws {
        // Same scheme+host+port with different case and a trailing
        // path/slash still matches; a different port does not.
        let sealed = try ChatImageCrypto.seal(Data("origin".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: "https://Stamped.Example/")!] }
        )

        _ = try await loader.plaintext(
            for: Self.imageAttachment(sealed: sealed, server: Self.stampedServer)
        )
        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: "https://Stamped.Example/", sha256: sealed.sha256Hex)],
                       "case-insensitive origin match honors the stamp, binding to the ALLOWLIST URL")

        let other = try ChatImageCrypto.seal(Data("origin-port".utf8))
        let portClient = ServerRecordingBlossomClient(blobs: [other.sha256Hex: other.blob])
        let portLoader = ChatImageLoader(
            blossomClient: portClient,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: "https://stamped.example:8443")!] }
        )
        _ = try await portLoader.plaintext(
            for: Self.imageAttachment(sealed: other, server: Self.stampedServer)
        )
        let portDownloads = await portClient.downloads
        XCTAssertEqual(portDownloads, [.init(server: nil, sha256: other.sha256Hex)],
                       "a different port is a different origin — stamp not honored")
    }

    // MARK: - Video loader

    func test_videoLoader_stampedAttachment_downloadsViaBoundClient() async throws {
        let sealed = try ChatImageCrypto.seal(Data("video-bytes".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatVideoLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: Self.stampedServer)!] }
        )

        let poster = Self.imageAttachment(
            sealed: try ChatImageCrypto.seal(Data("poster".utf8)),
            server: Self.stampedServer
        )
        let attachment = ChatVideoAttachment(
            sha256: sealed.sha256Hex,
            mimeType: "video/mp4",
            byteSize: sealed.blob.count,
            width: 4, height: 4,
            durationSeconds: 1,
            encKey: sealed.key,
            poster: poster,
            server: Self.stampedServer
        )
        let url = try await loader.fileURL(for: attachment)

        XCTAssertEqual(try Data(contentsOf: url), Data("video-bytes".utf8))
        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: Self.stampedServer, sha256: sealed.sha256Hex)])
    }

    // MARK: - Voice loader

    func test_voiceLoader_stampedAttachment_downloadsViaBoundClient() async throws {
        let sealed = try ChatImageCrypto.seal(Data("voice-bytes".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatVoiceLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: Self.stampedServer)!] }
        )

        let attachment = ChatVoiceAttachment(
            sha256: sealed.sha256Hex,
            mimeType: "audio/mp4",
            byteSize: sealed.blob.count,
            durationSeconds: 1,
            encKey: sealed.key,
            waveform: [0, 1, 2],
            server: Self.stampedServer
        )
        let url = try await loader.fileURL(for: attachment)

        XCTAssertEqual(try Data(contentsOf: url), Data("voice-bytes".utf8))
        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: Self.stampedServer, sha256: sealed.sha256Hex)])
    }

    func test_stampWithPathAndQuery_bindsToAllowlistURL_notRawStamp() async throws {
        // The stamp's origin proves allowlist membership, but its
        // path/query are peer-chosen bytes — the request must be built
        // from the allowlist's own URL, never the raw stamp.
        let sealed = try ChatImageCrypto.seal(Data("path-query".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: Self.stampedServer)!] }
        )

        _ = try await loader.plaintext(
            for: Self.imageAttachment(
                sealed: sealed,
                server: Self.stampedServer + "/evil/prefix?track=1"
            )
        )

        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: Self.stampedServer, sha256: sealed.sha256Hex)],
                       "binding must use the allowlist URL, stripping the peer's path/query")
    }

    func test_httpStamp_neverHonored_evenWhenHTTPEndpointConfigured() async throws {
        // The peer-influenced path is https-only regardless of what
        // the user configured — an http local-dev endpoint still works
        // through the LIVE client, it just can't be stamp-routed.
        let sealed = try ChatImageCrypto.seal(Data("http-stamp".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: "http://192.168.1.10:3000")!] }
        )

        _ = try await loader.plaintext(
            for: Self.imageAttachment(sealed: sealed, server: "http://192.168.1.10:3000")
        )

        let downloads = await client.downloads
        XCTAssertEqual(downloads, [.init(server: nil, sha256: sealed.sha256Hex)],
                       "http stamps fall back to the live client even when the endpoint is configured")
    }

    func test_defaultPortNormalization_bothDirections() async throws {
        // "https://a.example:443" and "https://a.example" are the same
        // origin — explicit default port on either side still matches.
        let sealedA = try ChatImageCrypto.seal(Data("port-a".utf8))
        let clientA = ServerRecordingBlossomClient(blobs: [sealedA.sha256Hex: sealedA.blob])
        let loaderA = ChatImageLoader(
            blossomClient: clientA,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: "https://stamped.example")!] }
        )
        _ = try await loaderA.plaintext(
            for: Self.imageAttachment(sealed: sealedA, server: "https://stamped.example:443")
        )
        let downloadsA = await clientA.downloads
        XCTAssertEqual(downloadsA, [.init(server: "https://stamped.example", sha256: sealedA.sha256Hex)],
                       "stamp with explicit :443 matches the portless allowlist entry")

        let sealedB = try ChatImageCrypto.seal(Data("port-b".utf8))
        let clientB = ServerRecordingBlossomClient(blobs: [sealedB.sha256Hex: sealedB.blob])
        let loaderB = ChatImageLoader(
            blossomClient: clientB,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: "https://stamped.example:443")!] }
        )
        _ = try await loaderB.plaintext(
            for: Self.imageAttachment(sealed: sealedB, server: Self.stampedServer)
        )
        let downloadsB = await clientB.downloads
        XCTAssertEqual(downloadsB, [.init(server: "https://stamped.example:443", sha256: sealedB.sha256Hex)],
                       "portless stamp matches the allowlist entry with explicit :443")
    }

    // MARK: - In-flight deduplication

    func test_imageLoader_concurrentRequestsSameSha_downloadOnce() async throws {
        // Two simultaneous requests for the same blob must share ONE
        // download — the allowlist await is a suspension point, so the
        // inflight check-and-insert has to stay contiguous after it.
        let sealed = try ChatImageCrypto.seal(Data("dedup-image".utf8))
        let client = ServerRecordingBlossomClient(
            blobs: [sealed.sha256Hex: sealed.blob],
            delayNanos: 200_000_000
        )
        let loader = ChatImageLoader(
            blossomClient: client,
            cacheDirectory: Self.tempDir(),
            allowedStampServers: { [URL(string: Self.stampedServer)!] }
        )
        let attachment = Self.imageAttachment(sealed: sealed, server: Self.stampedServer)

        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await loader.plaintext(for: attachment) }
            group.addTask { try await loader.plaintext(for: attachment) }
            for try await plaintext in group {
                XCTAssertEqual(plaintext, Data("dedup-image".utf8))
            }
        }

        let downloads = await client.downloads
        XCTAssertEqual(downloads.count, 1,
                       "concurrent requests for one sha must share a single download")
    }

    func test_videoLoader_concurrentRequestsSameSha_downloadOnce() async throws {
        let sealed = try ChatImageCrypto.seal(Data("dedup-video".utf8))
        let client = ServerRecordingBlossomClient(
            blobs: [sealed.sha256Hex: sealed.blob],
            delayNanos: 200_000_000
        )
        let loader = ChatVideoLoader(blossomClient: client, cacheDirectory: Self.tempDir())
        let poster = Self.imageAttachment(
            sealed: try ChatImageCrypto.seal(Data("p".utf8)), server: nil
        )
        let attachment = ChatVideoAttachment(
            sha256: sealed.sha256Hex, mimeType: "video/mp4",
            byteSize: sealed.blob.count, width: 4, height: 4,
            durationSeconds: 1, encKey: sealed.key, poster: poster, server: nil
        )

        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await loader.fileURL(for: attachment) }
            group.addTask { try await loader.fileURL(for: attachment) }
            for try await url in group {
                XCTAssertEqual(try Data(contentsOf: url), Data("dedup-video".utf8))
            }
        }

        let downloads = await client.downloads
        XCTAssertEqual(downloads.count, 1)
    }

    func test_voiceLoader_concurrentRequestsSameSha_downloadOnce() async throws {
        let sealed = try ChatImageCrypto.seal(Data("dedup-voice".utf8))
        let client = ServerRecordingBlossomClient(
            blobs: [sealed.sha256Hex: sealed.blob],
            delayNanos: 200_000_000
        )
        let loader = ChatVoiceLoader(blossomClient: client, cacheDirectory: Self.tempDir())
        let attachment = ChatVoiceAttachment(
            sha256: sealed.sha256Hex, mimeType: "audio/mp4",
            byteSize: sealed.blob.count, durationSeconds: 1,
            encKey: sealed.key, waveform: [0, 1], server: nil
        )

        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await loader.fileURL(for: attachment) }
            group.addTask { try await loader.fileURL(for: attachment) }
            for try await url in group {
                XCTAssertEqual(try Data(contentsOf: url), Data("dedup-voice".utf8))
            }
        }

        let downloads = await client.downloads
        XCTAssertEqual(downloads.count, 1)
    }

    // MARK: - fixtures

    private static func imageAttachment(
        sealed: ChatImageCrypto.Sealed,
        server: String?
    ) -> ChatImageAttachment {
        ChatImageAttachment(
            sha256: sealed.sha256Hex,
            mimeType: "image/jpeg",
            byteSize: sealed.blob.count,
            width: 4, height: 4,
            encKey: sealed.key,
            blurhash: "LEHV6nWB2yk8",
            server: server
        )
    }

    private static func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loader-binding-\(UUID().uuidString)", isDirectory: true)
    }

    /// Serves sealed blobs by sha and records, for every download, the
    /// server the client was `bound(toServer:)` to — `nil` for a
    /// download through the live (unbound) client.
    private actor ServerRecordingBlossomClient: BlossomClient {
        struct Download: Equatable {
            let server: String?
            let sha256: String
        }

        private let blobs: [String: Data]
        /// Artificial per-download latency so concurrency tests can
        /// guarantee both callers overlap the in-flight window.
        private let delayNanos: UInt64
        private(set) var downloads: [Download] = []

        init(blobs: [String: Data], delayNanos: UInt64 = 0) {
            self.blobs = blobs
            self.delayNanos = delayNanos
        }

        func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
            throw BlossomError.badStatus(500)
        }

        func download(sha256: String) async throws -> Data {
            try await serve(sha256: sha256, server: nil)
        }

        nonisolated func bound(toServer serverURL: String) -> any BlossomClient {
            Bound(server: serverURL, recorder: self)
        }

        fileprivate func serve(sha256: String, server: String?) async throws -> Data {
            downloads.append(Download(server: server, sha256: sha256))
            if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
            guard let blob = blobs[sha256] else { throw BlossomError.badStatus(404) }
            return blob
        }

        private struct Bound: BlossomClient {
            let server: String
            let recorder: ServerRecordingBlossomClient

            func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
                throw BlossomError.badStatus(500)
            }

            func download(sha256: String) async throws -> Data {
                try await recorder.serve(sha256: sha256, server: server)
            }
        }
    }
}
