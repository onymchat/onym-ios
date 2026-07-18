import UIKit

/// Funnels a picked image through downscale → JPEG-budget → BlurHash so
/// what we encrypt + upload to Blossom is a sensibly-sized display
/// image, and the message carries a placeholder. Sibling to
/// `GroupAvatarImage` but tuned for full-frame photos (larger edge,
/// larger byte budget) rather than tiny avatars.
enum ChatImageEncoder {
    /// Longest-edge cap in pixels for the transmitted image.
    static let maxEdge: CGFloat = 2048
    /// Soft byte budget for the JPEG (quality steps down to fit).
    static let maxBytes = 2 * 1024 * 1024

    struct Encoded: Equatable {
        let jpeg: Data
        let width: Int
        let height: Int
        let blurhash: String
    }

    static func encode(fromImageData data: Data) -> Encoded? {
        guard let image = UIImage(data: data) else { return nil }
        return encode(image)
    }

    static func encode(_ image: UIImage) -> Encoded? {
        let scaled = downscale(image, maxEdge: maxEdge)
        var quality: CGFloat = 0.85
        var jpeg = scaled.jpegData(compressionQuality: quality)
        while let data = jpeg, data.count > maxBytes, quality > 0.4 {
            quality -= 0.1
            jpeg = scaled.jpegData(compressionQuality: quality)
        }
        guard let out = jpeg else { return nil }
        let blurhash = Blurhash.encode(scaled) ?? ""
        return Encoded(
            jpeg: out,
            width: Int(scaled.size.width),
            height: Int(scaled.size.height),
            blurhash: blurhash
        )
    }

    /// Aspect-preserving downscale so the longest edge is ≤ `maxEdge`.
    /// `scale = 1` so the rendered size is in pixels.
    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let src = image.size
        let longest = max(src.width, src.height)
        let factor = longest > maxEdge ? maxEdge / longest : 1.0
        let target = CGSize(
            width: max(1, floor(src.width * factor)),
            height: max(1, floor(src.height * factor))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
