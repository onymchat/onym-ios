import CryptoKit
import Foundation
import OnymTransportBlossom

/// Serves restored attachment ciphertext before going to the network.
///
/// A snapshot taken with `.includeCiphertext` carries the exact bytes
/// the blob store served, so a restore can put media back that the blob
/// operator has since dropped — which is most of the reason to pay for
/// carrying it. But the media loaders reach for a `BlossomClient`, and
/// bytes written to a directory none of them reads are bytes nobody ever
/// sees. Counting those as "restored" would be a lie in the summary.
///
/// Wrapping the client is what makes them real, and it covers every
/// loader at once — image, voice, and video all take a `BlossomClient`,
/// so none of them needs to know this exists.
///
/// **Nothing prunes this directory yet** (onymchat/onym-ios#283).
/// Restored ciphertext outlives the chat it belongs to, which is the
/// wrong default in a product that argues deletion means something. It
/// is only ever written by an `.includeCiphertext` restore, which is not
/// selectable yet, and must be fixed before that policy becomes
/// reachable.
public struct RestoredBlobClient: BlossomClient {
    private let restored: URL
    private let upstream: any BlossomClient

    public init(restoredDirectory: URL, upstream: any BlossomClient) {
        self.restored = restoredDirectory
        self.upstream = upstream
    }

    public func download(sha256: String) async throws -> Data {
        if let local = try? Data(contentsOf: restored.appending(path: sha256)) {
            // Verified before use. These bytes were checked when the
            // snapshot was composed and again when it was restored, but
            // they now sit in a directory on a device — and a content
            // address that does not match its content is exactly what a
            // loader must never decrypt against.
            let actual = SHA256.hash(data: local).map { String(format: "%02x", $0) }.joined()
            if actual == sha256 { return local }
        }
        return try await upstream.download(sha256: sha256)
    }

    public func upload(_ data: Data, mimeType: String) async throws -> BlobDescriptor {
        try await upstream.upload(data, mimeType: mimeType)
    }

    /// Rebinding follows the upstream to its new server and keeps the
    /// local directory — restored bytes are addressed by content, so
    /// they are as valid against one server as another.
    public func bound(toServer serverURL: String) -> any BlossomClient {
        RestoredBlobClient(
            restoredDirectory: restored, upstream: upstream.bound(toServer: serverURL))
    }
}
