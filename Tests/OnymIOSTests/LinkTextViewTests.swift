import XCTest
@testable import OnymChatsUI

/// `LinkTextView.point(inside:)` — the bubble body only claims
/// touches that land on a link glyph; everything else must fall
/// through to the cell (scroll, context menu, swipe-to-reply). A
/// false positive here opens a sender-controlled URL from a touch
/// the user aimed at something else, so every miss case is pinned.
@MainActor
final class LinkTextViewTests: XCTestCase {

    private func makeView(_ body: String, width: CGFloat = 300) -> LinkTextView {
        let view = LinkTextView()
        view.setBody(body, font: .systemFont(ofSize: 17), color: .black)
        let size = view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        view.layoutIfNeeded()
        return view
    }

    /// Center of the rendered rect for the character at `index`.
    private func centerOfChar(_ index: Int, in view: LinkTextView) throws -> CGPoint {
        let start = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: index))
        let end = try XCTUnwrap(view.position(from: start, offset: 1))
        let rect = view.firstRect(for: try XCTUnwrap(view.textRange(from: start, to: end)))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func test_pointOnLinkGlyph_hits() throws {
        let view = makeView("see https://onym.foundation now")
        // Inside the URL run ("see " is 4 chars).
        let point = try centerOfChar(10, in: view)
        XCTAssertTrue(view.point(inside: point, with: nil))
    }

    func test_pointOnProse_misses() throws {
        let view = makeView("see https://onym.foundation now")
        let point = try centerOfChar(0, in: view)
        XCTAssertFalse(view.point(inside: point, with: nil),
                       "prose must fall through to the cell")
    }

    func test_pointOutsideBounds_misses() throws {
        // `hitTest` probes with out-of-bounds points (enlarged tap
        // areas); a bubble-padding tap beside a trailing link must
        // not clamp onto it.
        let view = makeView("tap https://onym.foundation")
        let onLink = try centerOfChar(10, in: view)
        XCTAssertFalse(view.point(inside: CGPoint(x: -6, y: onLink.y), with: nil))
        XCTAssertFalse(view.point(inside: CGPoint(x: view.bounds.maxX + 6, y: onLink.y), with: nil))
        XCTAssertFalse(view.point(inside: CGPoint(x: onLink.x, y: view.bounds.maxY + 6), with: nil))
    }

    func test_bodyStartingWithURL_firstGlyphHits() throws {
        // `.layout(.left)` is nil at the document start — the fallback
        // keeps a leading URL tappable on its very first character.
        let view = makeView("https://onym.foundation first")
        let point = try centerOfChar(0, in: view)
        XCTAssertTrue(view.point(inside: point, with: nil))
    }

    func test_emptySpaceRightOfLinkLine_misses() throws {
        // The URL ends its line; the empty area right of the last
        // glyph is inside bounds, and `closestPosition` clamps to
        // that glyph — the rendered-rect check must reject it.
        let view = makeView("https://a.example\nsecond line is much longer text")
        let lastLinkChar = try centerOfChar(16, in: view)
        let rightOfLine = CGPoint(x: view.bounds.maxX - 2, y: lastLinkChar.y)
        XCTAssertFalse(view.point(inside: rightOfLine, with: nil))
    }

    func test_emptyBody_misses() {
        let view = makeView("")
        XCTAssertFalse(view.point(inside: CGPoint(x: 1, y: 1), with: nil))
    }
}
