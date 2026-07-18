import Foundation

/// An encrypted video attached to a chat message.
///
/// Same envelope model as `ChatImageAttachment`: the (720p-transcoded)
/// video is AES-GCM-encrypted with a **per-video random key** and the
/// ciphertext is uploaded to Blossom (`blossom.onym.app`), addressed by
/// the SHA-256 of the *stored* bytes. This descriptor travels inside the
/// already-sealed, per-recipient `ChatMessagePayload`.
///
/// Unlike an image, a video can't render a cheap inline placeholder from
/// a blurhash alone and it's too big to fetch eagerly, so a **separate
/// encrypted poster blob** ships alongside it: [poster] is a full
/// `ChatImageAttachment` (its own blob + key + blurhash + dimensions)
/// carrying the first frame. The bubble renders the poster's blurhash
/// instantly, swaps in the sharp poster when its small blob loads, and
/// only downloads the (large) video blob when the user taps play.
///
///  - [sha256] locates the video blob (`GET <server>/<sha256>`) and lets
///    the receiver verify integrity before decrypting.
///  - [encKey] is the 32-byte AES-GCM key for the video blob. The blob
///    is `AES.GCM.SealedBox.combined` (nonce ‖ ciphertext ‖ tag), so no
///    separate nonce travels.
///  - [durationSeconds] drives the duration pill on the bubble poster.
///  - [width]/[height] are the transcoded pixel dimensions so the bubble
///    reserves the right aspect ratio before the poster loads.
///  - [server] is the blob server base URL; `nil` means "use the app
///    default", so a future server migration doesn't strand old rows.
///
/// Additive on the wire: `ChatMessagePayload.videoAttachment` is
/// optional, so a sender that omits it decodes to `nil` on any receiver
/// and an older receiver ignores the unknown key — no `version` bump.
struct ChatVideoAttachment: Codable, Equatable, Sendable {
    /// Lowercase hex SHA-256 of the encrypted video blob. Doubles as the
    /// Blossom address and the download-integrity check.
    let sha256: String
    /// MIME type of the *plaintext* video, e.g. `video/mp4`.
    let mimeType: String
    /// Size of the encrypted video blob in bytes (for limits / progress).
    let byteSize: Int
    /// Transcoded video pixel dimensions — drive the bubble aspect ratio.
    let width: Int
    let height: Int
    /// Playback duration in seconds — rendered as an `m:ss` pill.
    let durationSeconds: Double
    /// 32-byte AES-GCM key, unique to this video blob.
    let encKey: Data
    /// The poster frame, shipped as its own encrypted image blob (with
    /// its own key + blurhash). Rendered in the bubble before playback.
    let poster: ChatImageAttachment
    /// Blob server base URL (e.g. `https://blossom.onym.app`). `nil`
    /// falls back to the app's configured default.
    let server: String?

    enum CodingKeys: String, CodingKey {
        case sha256
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case width
        case height
        case durationSeconds = "duration_seconds"
        case encKey = "enc_key"
        case poster
        case server
    }
}
