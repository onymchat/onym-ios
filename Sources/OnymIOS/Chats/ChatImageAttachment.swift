import Foundation

/// An encrypted image attached to a chat message.
///
/// The image is AES-GCM-encrypted with a **per-image random key** and
/// the ciphertext is uploaded to a Blossom blob server
/// (`blossom.onym.app`), addressed by the SHA-256 of the *stored*
/// bytes. This descriptor — which travels inside the already-sealed,
/// per-recipient `ChatMessagePayload` — is everything a receiver needs
/// to fetch and decrypt it:
///
///  - [sha256] locates the blob (`GET <server>/<sha256>`) and lets the
///    receiver verify integrity before decrypting.
///  - [encKey] is the 32-byte AES-GCM key. It's only ever in the clear
///    inside the sealed envelope; the blob on Blossom is opaque
///    ciphertext, and the uploaded bytes are `AES.GCM.SealedBox.combined`
///    (nonce ‖ ciphertext ‖ tag), so no separate nonce is carried.
///  - [blurhash] renders instantly as a placeholder while the full
///    blob downloads (we deliberately ship blurhash-only, not an inline
///    thumbnail, to keep the sealed envelope inside relay size limits).
///  - [width]/[height] are the decoded pixel dimensions so the bubble
///    can reserve the right aspect ratio before the image loads.
///  - [server] is the blob server base URL; `nil` means "use the app
///    default", so a future server migration doesn't strand old rows.
///
/// Additive on the wire: `ChatMessagePayload.attachment` is optional, so
/// a sender that omits it decodes to `nil` on any receiver and an older
/// receiver ignores the unknown key — no `version` bump required.
struct ChatImageAttachment: Codable, Equatable, Sendable {
    /// Lowercase hex SHA-256 of the encrypted blob. Doubles as the
    /// Blossom address and the download-integrity check.
    let sha256: String
    /// MIME type of the *plaintext* image, e.g. `image/jpeg`.
    let mimeType: String
    /// Size of the encrypted blob in bytes (for limits / progress UI).
    let byteSize: Int
    /// Decoded image pixel dimensions — drive the bubble's aspect ratio
    /// before the blob loads.
    let width: Int
    let height: Int
    /// 32-byte AES-GCM key, unique to this image.
    let encKey: Data
    /// BlurHash placeholder string (rendered while the blob downloads).
    let blurhash: String
    /// Blob server base URL (e.g. `https://blossom.onym.app`). `nil`
    /// falls back to the app's configured default.
    let server: String?

    enum CodingKeys: String, CodingKey {
        case sha256
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case width
        case height
        case encKey = "enc_key"
        case blurhash
        case server
    }
}
