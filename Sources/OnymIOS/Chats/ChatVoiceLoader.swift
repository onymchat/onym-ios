import Foundation

/// Fetches + decrypts chat voice blobs for playback, caching the decrypted
/// `.m4a` on disk keyed by the blob SHA-256. Downloads the ciphertext from
/// Blossom, verifies the hash, AES-GCM-decrypts with the per-clip key, and
/// writes a plaintext `.m4a` an `AVAudioPlayer` can play. Concurrent
/// requests for the same blob share one download.
///
/// Sibling to `ChatVideoLoader` — the voice blob is small, but it's still
/// only pulled on play; the bubble's waveform + duration render from the
/// descriptor alone, so nothing downloads on receipt.
actor ChatVoiceLoader {
    private let blossomClient: any BlossomClient
    private let cacheDir: URL
    private var inflight: [String: Task<URL, Error>] = [:]

    init(blossomClient: any BlossomClient, cacheDirectory: URL? = nil) {
        self.blossomClient = blossomClient
        self.cacheDir = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnymChatVoice", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    /// Local decrypted file URL for `attachment`, downloading + decrypting
    /// on first request and serving the cached file after. Throws on
    /// download / integrity / decrypt failure.
    func fileURL(for attachment: ChatVoiceAttachment) async throws -> URL {
        let key = attachment.sha256
        let dest = cacheFileURL(key)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        if let existing = inflight[key] { return try await existing.value }

        let client = blossomClient
        let task = Task<URL, Error> {
            let blob = try await client.download(sha256: attachment.sha256)
            let plaintext = try ChatImageCrypto.open(
                blob: blob, key: attachment.encKey, expectedSha256Hex: attachment.sha256
            )
            try plaintext.write(to: dest, options: .completeFileProtection)
            return dest
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    private func cacheFileURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent(key).appendingPathExtension("m4a")
    }
}
