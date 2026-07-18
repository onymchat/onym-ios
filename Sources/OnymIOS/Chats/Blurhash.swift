import UIKit

/// Minimal BlurHash (woltapp/blurhash) encoder + decoder. Chat images
/// ship a BlurHash string in `ChatImageAttachment.blurhash` (not an
/// inline thumbnail), so the bubble can render a smooth colour
/// placeholder at the right aspect ratio while the real blob downloads
/// and decrypts.
enum Blurhash {
    private static let alphabet = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    )

    // MARK: - Encode

    /// Encode `image` into a BlurHash string. `components` is the (x, y)
    /// detail grid (1…9 each); 4×3 is a good default for photos.
    static func encode(_ image: UIImage, components: (Int, Int) = (4, 3)) -> String? {
        let xc = max(1, min(9, components.0))
        let yc = max(1, min(9, components.1))
        guard let cg = image.cgImage else { return nil }
        // Downscale to a small work size for speed; blurhash is
        // low-frequency so a 32px-ish sample is plenty.
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var factors: [[Double]] = []
        for j in 0..<yc {
            for i in 0..<xc {
                let norm = (i == 0 && j == 0) ? 1.0 : 2.0
                var r = 0.0, g = 0.0, b = 0.0
                for y in 0..<h {
                    for x in 0..<w {
                        let basis = norm
                            * cos(Double.pi * Double(i) * Double(x) / Double(w))
                            * cos(Double.pi * Double(j) * Double(y) / Double(h))
                        let o = (y * w + x) * 4
                        r += basis * sRGBToLinear(pixels[o])
                        g += basis * sRGBToLinear(pixels[o + 1])
                        b += basis * sRGBToLinear(pixels[o + 2])
                    }
                }
                let scale = 1.0 / Double(w * h)
                factors.append([r * scale, g * scale, b * scale])
            }
        }

        let dc = factors[0]
        let ac = Array(factors.dropFirst())
        var hash = ""
        hash += encode83(xc - 1 + (yc - 1) * 9, length: 1)

        let maxAC = ac.flatMap { $0 }.map { abs($0) }.max() ?? 0
        let quantMax = ac.isEmpty ? 0 : max(0, min(82, Int(maxAC * 166 - 0.5)))
        hash += ac.isEmpty
            ? encode83(0, length: 1)
            : encode83(quantMax, length: 1)
        let actualMax = ac.isEmpty ? 1.0 : (Double(quantMax) + 1) / 166.0

        hash += encode83(encodeDC(dc), length: 4)
        for comp in ac { hash += encode83(encodeAC(comp, max: actualMax), length: 2) }
        return hash
    }

    // MARK: - Decode

    /// Decode a BlurHash into a `size`-pixel placeholder image.
    static func decode(_ hash: String, size: CGSize, punch: Double = 1.0) -> UIImage? {
        let chars = Array(hash)
        guard chars.count >= 6 else { return nil }
        let sizeFlag = decode83(String(chars[0]))
        let yc = sizeFlag / 9 + 1
        let xc = sizeFlag % 9 + 1
        guard chars.count == 4 + 2 * xc * yc else { return nil }
        let quantMax = decode83(String(chars[1]))
        let maxValue = (Double(quantMax) + 1) / 166.0 * punch

        var colors = [[Double]](repeating: [0, 0, 0], count: xc * yc)
        colors[0] = decodeDC(decode83(String(chars[2..<6])))
        for i in 1..<(xc * yc) {
            let from = 4 + i * 2
            colors[i] = decodeAC(decode83(String(chars[from..<(from + 2)])), max: maxValue)
        }

        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<yc {
                    for i in 0..<xc {
                        let basis = cos(Double.pi * Double(x) * Double(i) / Double(w))
                            * cos(Double.pi * Double(y) * Double(j) / Double(h))
                        let c = colors[i + j * xc]
                        r += c[0] * basis; g += c[1] * basis; b += c[2] * basis
                    }
                }
                let o = (y * w + x) * 4
                pixels[o] = linearToSRGB(r)
                pixels[o + 1] = linearToSRGB(g)
                pixels[o + 2] = linearToSRGB(b)
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - base83 + colour helpers

    private static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        for i in 1...length {
            let digit = (value / Int(pow(83.0, Double(length - i)))) % 83
            result.append(alphabet[digit])
        }
        return result
    }

    private static func decode83(_ s: String) -> Int {
        s.reduce(0) { acc, c in acc * 83 + (alphabet.firstIndex(of: c) ?? 0) }
    }

    private static func sRGBToLinear(_ v: UInt8) -> Double {
        let x = Double(v) / 255.0
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ v: Double) -> UInt8 {
        let x = max(0, min(1, v))
        let s = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, round(s * 255))))
    }

    private static func encodeDC(_ c: [Double]) -> Int {
        let r = Int(linearToSRGB(c[0])), g = Int(linearToSRGB(c[1])), b = Int(linearToSRGB(c[2]))
        return (r << 16) + (g << 8) + b
    }

    private static func decodeDC(_ value: Int) -> [Double] {
        [sRGBToLinear(UInt8((value >> 16) & 255)),
         sRGBToLinear(UInt8((value >> 8) & 255)),
         sRGBToLinear(UInt8(value & 255))]
    }

    private static func encodeAC(_ c: [Double], max: Double) -> Int {
        func q(_ v: Double) -> Int {
            Int(Swift.max(0, Swift.min(18, floor(signPow(v / max, 0.5) * 9 + 9.5))))
        }
        return q(c[0]) * 19 * 19 + q(c[1]) * 19 + q(c[2])
    }

    private static func decodeAC(_ value: Int, max: Double) -> [Double] {
        let r = value / (19 * 19), g = (value / 19) % 19, b = value % 19
        func d(_ q: Int) -> Double { signPow((Double(q) - 9) / 9, 2.0) * max }
        return [d(r), d(g), d(b)]
    }

    private static func signPow(_ v: Double, _ exp: Double) -> Double {
        (v < 0 ? -1.0 : 1.0) * pow(abs(v), exp)
    }
}
