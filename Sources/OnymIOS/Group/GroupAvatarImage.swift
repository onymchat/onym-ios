import UIKit

/// Funnels every avatar source — gallery pick, Image Playground
/// generation, a future paste — through one square-crop / downscale /
/// JPEG-budget pipeline so the bytes that land on `ChatGroup.avatarJPEG`
/// (and therefore in a sealed NOSTR envelope) are always small enough
/// to ship.
///
/// The avatar renders at most ~96 pt, so 256×256 px covers @2x/@3x with
/// headroom while keeping the encode tiny. `maxBytes` is the *raw* JPEG
/// budget; base64 on the wire adds ~33 %, leaving the sealed payload
/// comfortably inside relay event-size limits.
enum GroupAvatarImage {
    /// Square edge length, in pixels, of the stored/transmitted image.
    static let dimension: CGFloat = 256
    /// Hard cap on the encoded JPEG. ~16 KB → ~22 KB base64.
    static let maxBytes = 16 * 1024

    /// Square-crop (centre), downscale to `dimension`px, then JPEG-encode
    /// at the highest quality that fits `maxBytes`. Returns `nil` only if
    /// the image can't be drawn at all. Orientation is normalised by the
    /// renderer, so EXIF-rotated camera shots come out upright.
    static func encode(_ image: UIImage) -> Data? {
        let square = squareScaled(image, to: dimension)
        // 256² is small; quality 0.8 usually already fits, but step down
        // for busy photos. The floor (0.2) is a safety net — if even that
        // overshoots we return it anyway rather than dropping the avatar.
        var quality: CGFloat = 0.8
        var encoded = square.jpegData(compressionQuality: quality)
        while let data = encoded, data.count > maxBytes, quality > 0.2 {
            quality -= 0.1
            encoded = square.jpegData(compressionQuality: quality)
        }
        return encoded
    }

    /// Convenience for the gallery path, which hands us raw file `Data`.
    static func encode(fromImageData data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return encode(image)
    }

    /// Centre-crop to a square, then render at exactly `edge`×`edge` px
    /// (`scale = 1` so the output is in pixels, not points).
    private static func squareScaled(_ image: UIImage, to edge: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: edge, height: edge)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let src = image.size
            let side = min(src.width, src.height)
            // aspect-fill: scale so the short side maps to `edge`, then
            // centre the overflow off-canvas.
            let scale = edge / side
            let drawSize = CGSize(width: src.width * scale, height: src.height * scale)
            let origin = CGPoint(
                x: (edge - drawSize.width) / 2,
                y: (edge - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
