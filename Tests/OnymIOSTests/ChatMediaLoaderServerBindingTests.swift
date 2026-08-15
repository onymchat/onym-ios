import Foundation
import XCTest
@testable import OnymIOS
import OnymChatsCore
import OnymTransportBlossom

/// The read half of the server-stamp contract: all three media loaders
/// must download a stamped attachment through a client BOUND to the
/// attachment's `server` — the one the sender actually uploaded to —
/// not the live client, whose base URL moves the moment the user picks
/// a different Blossom server. Legacy rows without a stamp fall back
/// to the live client.
final class ChatMediaLoaderServerBindingTests: XCTestCase {
    private static let stampedServer = "https://stamped.example"

    // MARK: - Image loader

    func test_imageLoader_stampedAttachment_downloadsViaBoundClient() async throws {
        let sealed = try ChatImageCrypto.seal(Data("image-bytes".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatImageLoader(blossomClient: client, cacheDirectory: Self.tempDir())

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

    // MARK: - Video loader

    func test_videoLoader_stampedAttachment_downloadsViaBoundClient() async throws {
        let sealed = try ChatImageCrypto.seal(Data("video-bytes".utf8))
        let client = ServerRecordingBlossomClient(blobs: [sealed.sha256Hex: sealed.blob])
        let loader = ChatVideoLoader(blossomClient: client, cacheDirectory: Self.tempDir())

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
        let loader = ChatVoiceLoader(blossomClient: client, cacheDirectory: Self.tempDir())

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
        private(set) var downloads: [Download] = []

        init(blobs: [String: Data]) {
            self.blobs = blobs
        }

        func upload(_ blob: Data, mimeType: String) async throws -> BlobDescriptor {
            throw BlossomError.badStatus(500)
        }

        func download(sha256: String) async throws -> Data {
            try serve(sha256: sha256, server: nil)
        }

        nonisolated func bound(toServer serverURL: String) -> any BlossomClient {
            Bound(server: serverURL, recorder: self)
        }

        fileprivate func serve(sha256: String, server: String?) throws -> Data {
            downloads.append(Download(server: server, sha256: sha256))
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
