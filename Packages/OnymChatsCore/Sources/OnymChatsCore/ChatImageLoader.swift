import UIKit
import OnymTransportBlossom

/// Fetches + decrypts chat image blobs for rendering, with in-memory
/// and on-disk caches keyed by the blob SHA-256. Downloads the
/// ciphertext from Blossom, verifies the hash, AES-GCM-decrypts with
/// the per-image key from the attachment, and caches the plaintext so
/// re-renders (and next launch) don't re-fetch. Concurrent requests for
/// the same blob share one download.
///
/// The blob is only ever pulled lazily at render time — receiving a
/// message never touches the network.
public actor ChatImageLoader {
    private let blossomClient: any BlossomClient
    private let cacheDir: URL
    private var memory: [String: UIImage] = [:]
    private var inflight: [String: Task<Data, Error>] = [:]

    public init(blossomClient: any BlossomClient, cacheDirectory: URL? = nil) {
        self.blossomClient = blossomClient
        self.cacheDir = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnymChatImages", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    /// Decrypted image for `attachment`. Throws on download / integrity
    /// / decrypt failure.
    public func image(for attachment: ChatImageAttachment) async throws -> UIImage {
        let key = attachment.sha256
        if let cached = memory[key] { return cached }
        if let data = try? Data(contentsOf: fileURL(key)), let img = UIImage(data: data) {
            memory[key] = img
            return img
        }

        let plaintext = try await downloadAndDecrypt(attachment)
        guard let image = UIImage(data: plaintext) else {
            throw BlossomError.malformedResponse
        }
        writeDisk(key, plaintext)
        memory[key] = image
        return image
    }

    /// The **exact** decrypted bytes of `attachment`.
    ///
    /// Distinct from `image(for:)` on purpose. A `UIImage` is a decoded
    /// bitmap, and re-encoding one produces different bytes with a
    /// different digest — which is precisely the value that
    /// authenticates a reported photo against the sender's signature.
    /// Anything disclosing evidence must take the bytes from here and
    /// never round-trip them through an image.
    ///
    /// The disk cache already holds the plaintext verbatim, so a photo
    /// the user has looked at costs nothing to re-read.
    public func plaintext(for attachment: ChatImageAttachment) async throws -> Data {
        let key = attachment.sha256
        if let cached = try? Data(contentsOf: fileURL(key)) { return cached }
        let plaintext = try await downloadAndDecrypt(attachment)
        writeDisk(key, plaintext)
        if let image = UIImage(data: plaintext) { memory[key] = image }
        return plaintext
    }

    /// Sender-side warm cache: after uploading, prime the decrypted
    /// image so the sender renders instantly without re-downloading.
    func prime(sha256: String, plaintext: Data) {
        writeDisk(sha256, plaintext)
        if let image = UIImage(data: plaintext) { memory[sha256] = image }
    }

    // MARK: - Private

    private func downloadAndDecrypt(_ attachment: ChatImageAttachment) async throws -> Data {
        let key = attachment.sha256
        if let existing = inflight[key] { return try await existing.value }
        // Fetch from the server STAMPED into the attachment — the one
        // the sender actually uploaded to — not whatever server is
        // currently configured (the live client's base URL moves the
        // moment the user picks a different server). Legacy rows
        // without a stamp fall back to the live client.
        let client = attachment.server.map { blossomClient.bound(toServer: $0) }
            ?? blossomClient
        let task = Task<Data, Error> {
            let blob = try await client.download(sha256: attachment.sha256)
            return try ChatImageCrypto.open(
                blob: blob, key: attachment.encKey, expectedSha256Hex: attachment.sha256
            )
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    private func fileURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent(key).appendingPathExtension("img")
    }

    /// Atomic, because a half-written cache file is no longer only a
    /// broken thumbnail. `plaintext(for:)` hands these bytes back
    /// verbatim as evidence, so a truncated file hashes to the wrong
    /// digest, fails its commitment check, and makes the photo
    /// permanently unreportable — with the picture still rendering fine
    /// from whatever decoded.
    private func writeDisk(_ key: String, _ data: Data) {
        try? data.write(to: fileURL(key), options: [.atomic, .completeFileProtection])
    }
}
