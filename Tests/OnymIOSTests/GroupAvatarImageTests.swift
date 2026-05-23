import XCTest
import UIKit
@testable import OnymIOS

/// `GroupAvatarImage` is the single funnel every avatar source passes
/// through, so these lock the two invariants the wire format depends
/// on: the output is a 256×256 square, and it never exceeds the byte
/// budget — even for a high-entropy image that resists JPEG.
final class GroupAvatarImageTests: XCTestCase {

    func test_encode_producesSquare256pxJPEG() throws {
        // Deliberately non-square (landscape) so the centre-crop path runs.
        let source = solidImage(size: CGSize(width: 800, height: 400), color: .systemTeal)
        let data = try XCTUnwrap(GroupAvatarImage.encode(source))

        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size.width, GroupAvatarImage.dimension)
        XCTAssertEqual(decoded.size.height, GroupAvatarImage.dimension)
        XCTAssertLessThanOrEqual(data.count, GroupAvatarImage.maxBytes)
    }

    func test_encode_highEntropyImageStaysUnderBudget() throws {
        // Random per-pixel noise is the worst case for JPEG — if the
        // quality loop holds the budget here, real photos are safe.
        let source = noiseImage(edge: 512)
        let data = try XCTUnwrap(GroupAvatarImage.encode(source))
        XCTAssertLessThanOrEqual(data.count, GroupAvatarImage.maxBytes)
    }

    func test_encode_fromImageData_roundtrips() throws {
        let pngData = try XCTUnwrap(solidImage(size: CGSize(width: 256, height: 256), color: .red).pngData())
        let encoded = try XCTUnwrap(GroupAvatarImage.encode(fromImageData: pngData))
        XCTAssertLessThanOrEqual(encoded.count, GroupAvatarImage.maxBytes)
        XCTAssertNotNil(UIImage(data: encoded))
    }

    func test_encode_fromGarbageDataReturnsNil() {
        XCTAssertNil(GroupAvatarImage.encode(fromImageData: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - Helpers

    private func solidImage(size: CGSize, color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func noiseImage(edge: CGFloat) -> UIImage {
        let size = CGSize(width: edge, height: edge)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            var generator = SystemRandomNumberGenerator()
            let step = 2
            for x in stride(from: 0, to: Int(edge), by: step) {
                for y in stride(from: 0, to: Int(edge), by: step) {
                    let c = UIColor(
                        red: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        green: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        blue: CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255,
                        alpha: 1
                    )
                    c.setFill()
                    ctx.fill(CGRect(x: x, y: y, width: step, height: step))
                }
            }
        }
    }
}
