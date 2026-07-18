import Foundation

/// An encrypted voice message attached to a chat message.
///
/// Same envelope model as `ChatImageAttachment` / `ChatVideoAttachment`:
/// the recorded AAC (`.m4a`) clip is AES-GCM-encrypted with a **per-clip
/// random key** and the ciphertext is uploaded to Blossom
/// (`blossom.onym.app`), addressed by the SHA-256 of the *stored* bytes.
/// This descriptor travels inside the already-sealed, per-recipient
/// `ChatMessagePayload`.
///
/// Unlike a photo/video there's no visual thumbnail — the bubble renders
/// a play button, a static [waveform], and the [durationSeconds] pill from
/// the descriptor alone, and only downloads the (small) audio blob when the
/// user taps play (see `ChatVoiceLoader`).
///
///  - [sha256] locates the audio blob (`GET <server>/<sha256>`) and lets
///    the receiver verify integrity before decrypting.
///  - [encKey] is the 32-byte AES-GCM key for the blob. The blob is
///    `AES.GCM.SealedBox.combined` (nonce ‖ ciphertext ‖ tag), so no
///    separate nonce travels.
///  - [durationSeconds] drives the `m:ss` pill on the bubble.
///  - [waveform] is a small fixed-count array of normalized amplitude
///    samples (0…255), precomputed at record time so the bars render
///    before (and without ever) downloading the audio.
///  - [server] is the blob server base URL; `nil` means "use the app
///    default", so a future server migration doesn't strand old rows.
///
/// Additive on the wire: `ChatMessagePayload.voiceAttachment` is optional,
/// so a sender that omits it decodes to `nil` on any receiver and an older
/// receiver ignores the unknown key — no `version` bump.
struct ChatVoiceAttachment: Codable, Equatable, Sendable {
    /// Lowercase hex SHA-256 of the encrypted audio blob. Doubles as the
    /// Blossom address and the download-integrity check.
    let sha256: String
    /// MIME type of the *plaintext* audio, e.g. `audio/mp4` (AAC in an
    /// MPEG-4 container — the `.m4a` `AVAudioRecorder` produces).
    let mimeType: String
    /// Size of the encrypted audio blob in bytes (for limits / progress).
    let byteSize: Int
    /// Playback duration in seconds — rendered as an `m:ss` pill.
    let durationSeconds: Double
    /// 32-byte AES-GCM key, unique to this audio blob.
    let encKey: Data
    /// Normalized amplitude samples (0…255), a fixed small count (see
    /// `ChatVoiceRecorder.waveformBarCount`). Rendered as the bar chart in
    /// the bubble; precomputed so the waveform shows without the blob.
    let waveform: [UInt8]
    /// Blob server base URL (e.g. `https://blossom.onym.app`). `nil` falls
    /// back to the app's configured default.
    let server: String?

    enum CodingKeys: String, CodingKey {
        case sha256
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case durationSeconds = "duration_seconds"
        case encKey = "enc_key"
        case waveform
        case server
    }
}
