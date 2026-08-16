import UIKit

/// The message bubble's body: renders like the `UILabel` it replaced,
/// but URLs in the text are tappable.
///
/// A plain `UITextView` would claim *every* touch, which breaks the
/// bubble's surroundings — the table's scroll, the row context menu
/// (Copy/Report), and the swipe-to-reply pan all start on the text.
/// This subclass only accepts touches that land on a link character;
/// everything else falls through to the cell as if the text were a
/// label. Long-pressing a link gets the system link menu, which is
/// wanted; long-pressing anywhere else reaches the row's own menu.
final class LinkTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // Label-like metrics: no inner padding, no scrolling (so the
        // view self-sizes through Auto Layout like a label does).
        isEditable = false
        isScrollEnabled = false
        // Required for link taps; non-link touches never reach the
        // view (see `point(inside:)`), so selection can't start on
        // body text and fight the row's long-press menu.
        isSelectable = true
        backgroundColor = .clear
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A `UILabel` with no text measures zero; an empty `UITextView`
    /// measures one caret line. Media-only bubbles (image, voice) set
    /// an empty body and rely on it contributing no height — keep the
    /// label's behaviour.
    override var intrinsicContentSize: CGSize {
        guard let text, !text.isEmpty else { return .zero }
        return super.intrinsicContentSize
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // `hitTest` probes subviews with out-of-bounds points too (the
        // "enlarged tap area" mechanism) — without this guard, a tap
        // in the bubble's padding beside a body that ends in a link
        // would count as a hit on the link below.
        guard bounds.contains(point) else { return false }
        guard let attributed = attributedText, attributed.length > 0 else { return false }
        // Hit-test the links' rendered rects directly. Position-based
        // probing (`closestPosition` + tokenizer) is unreliable here:
        // it clamps empty-space touches onto the nearest glyph, and
        // inside a link TextKit 2 snaps positions to the link's
        // boundary — both produce wrong answers at the edges. The
        // per-line `selectionRects(for:)` of each link range are the
        // exact area where a tap visually lands on the link.
        var hit = false
        attributed.enumerateAttribute(
            .link, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, stop in
            guard value != nil,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end)
            else { return }
            for selection in selectionRects(for: textRange)
            where !selection.rect.isNull && selection.rect.contains(point) {
                hit = true
                stop.pointee = true
                return
            }
        }
        return hit
    }

    /// One shared detector — `NSDataDetector` construction is costly
    /// and cell reuse calls this per configure.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Set the bubble body: plain text plus `.link` runs for every
    /// URL the detector finds. Links keep the body's color and gain
    /// an underline — readable on both the accent-filled outgoing
    /// bubble and the tinted incoming one, with no extra color token.
    func setBody(_ body: String, font: UIFont, color: UIColor) {
        let attributed = NSMutableAttributedString(
            string: body,
            attributes: [.font: font, .foregroundColor: color]
        )
        if let detector = Self.linkDetector {
            let full = NSRange(body.startIndex..., in: body)
            for match in detector.matches(in: body, options: [], range: full) {
                guard let url = match.url else { continue }
                attributed.addAttribute(.link, value: url, range: match.range)
            }
        }
        linkTextAttributes = [
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        attributedText = attributed
    }
}
