import UIKit

/// Fetches + decrypts chat image blobs for rendering, with in-memory
/// and on-disk caches keyed by the blob SHA-256. Downloads the
/// ciphertext from Blossom, verifies the hash, AES-GCM-decrypts with
/// the per-image key from the attachment, and caches the plaintext so
/// re-renders (and next launch) don't re-fetch. Concurrent requests for
/// the same blob share one download.
///
/// The blob is only ever pulled lazily at render time — receiving a
/// message never touches the network.
actor ChatImageLoader {
    private let blossomClient: any BlossomClient
    private let cacheDir: URL
    private var memory: [String: UIImage] = [:]
    private var inflight: [String: Task<Data, Error>] = [:]

    init(blossomClient: any BlossomClient, cacheDirectory: URL? = nil) {
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
    func image(for attachment: ChatImageAttachment) async throws -> UIImage {
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
        let client = blossomClient
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

    private func writeDisk(_ key: String, _ data: Data) {
        try? data.write(to: fileURL(key), options: .completeFileProtection)
    }
}
