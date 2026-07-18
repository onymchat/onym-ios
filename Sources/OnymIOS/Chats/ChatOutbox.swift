import Foundation

/// On-disk store of the **encrypted** attachment blobs for outgoing
/// media that hasn't confirmed sent yet, keyed by the blob SHA-256.
///
/// Sending an image/video now inserts the optimistic bubble *before* the
/// upload, so a failed upload/fan-out leaves a `.failed` message the user
/// can resend. Resend must re-upload the exact same ciphertext (Blossom
/// addresses blobs by SHA-256, and the attachment descriptor already
/// committed to that hash), so we can't just re-seal — a fresh nonce
/// would change the bytes. Persisting the sealed blob here lets resend
/// re-upload the identical ciphertext, and lets it survive an app
/// restart.
///
/// Entries are removed once the message sends successfully (or is
/// deleted), so the store only ever holds blobs for in-flight / failed
/// sends. Video blobs can be large (≤95MB), which is why eviction on
/// success matters.
actor ChatOutbox {
    private let dir: URL

    init(directory: URL? = nil) {
        self.dir = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnymChatOutbox", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    /// Persist the sealed ciphertext `blob` under its `sha` so a later
    /// resend can re-upload the identical bytes.
    func store(sha: String, blob: Data) {
        try? blob.write(to: fileURL(sha), options: .completeFileProtection)
    }

    /// The stored ciphertext for `sha`, or `nil` if evicted / never stored.
    func load(sha: String) -> Data? {
        try? Data(contentsOf: fileURL(sha))
    }

    /// Drop the stored blob for `sha` (call on confirmed send or delete).
    func remove(sha: String) {
        try? FileManager.default.removeItem(at: fileURL(sha))
    }

    private func fileURL(_ sha: String) -> URL {
        dir.appendingPathComponent(sha).appendingPathExtension("blob")
    }
}
