import SwiftUI
import UIKit
import XCTest
@testable import OnymDesignTokens

/// Guards on the type scaling.
///
/// Two of these exist because the obvious implementation is wrong in a
/// way that compiles, reads plausibly, and ships. Neither would be
/// caught by a human looking at the screen at the default text size,
/// which is the setting almost every reviewer has.
final class DynamicTypeTests: XCTestCase {

    private func at(_ category: UIContentSizeCategory, _ body: () -> Void) {
        UITraitCollection(preferredContentSizeCategory: category).performAsCurrent(body)
    }

    // MARK: The half-point trap

    func testDefaultSettingLeavesEverySizeExactlyWhereItIs() {
        // `UIFontMetrics.scaledFont(for:)` rounds to whole points, and
        // does it at the *default* setting: 11.5pt comes back 12pt. The
        // app spends around sixty half-point sizes, so taking that route
        // changes text for every reader who never touched the setting.
        //
        // If this fails, someone has swapped the ratio for scaledFont.
        at(.large) {
            for size in [9.5, 10.5, 11.5, 12.5, 13.5, 14.5, 15.5, 16.5] as [CGFloat] {
                XCTAssertEqual(
                    OnymType.scale() * size, size, accuracy: 0.001,
                    "\(size)pt moved at the default setting — is scale() rounding?"
                )
            }
        }
    }

    func testHalfPointsSurviveScaling() {
        at(.accessibilityExtraExtraExtraLarge) {
            let scaled = OnymType.scale() * 13.5
            XCTAssertNotEqual(scaled, scaled.rounded(), accuracy: 0.0001,
                              "a scaled half-point size should not land on a whole point")
        }
    }

    // MARK: The silent-1.0 trap

    func testScaleActuallyReadsTheSetting() {
        // `scaledValue(for:)` with no trait collection does not consult
        // UITraitCollection.current — it answers 1.0 at every setting.
        // That version of this code looks like working Dynamic Type
        // support and delivers none of it.
        var ratios: [CGFloat] = []
        for category: UIContentSizeCategory in [
            .extraSmall, .large, .extraExtraExtraLarge,
            .accessibilityExtraExtraExtraLarge,
        ] {
            at(category) { ratios.append(OnymType.scale()) }
        }
        XCTAssertEqual(ratios, ratios.sorted(), "ratio should rise with the setting")
        XCTAssertLessThan(ratios.first!, 1.0, "extraSmall should shrink")
        XCTAssertGreaterThan(ratios.last!, 2.0,
                             "scale() is not reading the setting at all")
    }

    func testScaleIsExactlyOneAtTheDefault() {
        at(.large) { XCTAssertEqual(OnymType.scale(), 1.0, accuracy: 0.0001) }
    }

    // MARK: fixed
    //
    // SwiftUI publishes no way to read a `Font`'s resolved size, so
    // these measure what it actually draws rather than asserting
    // against a number that cannot be obtained.

    /// Height of one line rendered with `font`, built inside the trait
    /// so the token reads the right setting.
    @MainActor
    private func drawnHeight(at category: UIContentSizeCategory,
                             _ font: @escaping () -> Font) -> CGFloat {
        var height: CGFloat = 0
        UITraitCollection(preferredContentSizeCategory: category).performAsCurrent {
            let renderer = ImageRenderer(content: Text("Hg").font(font()).fixedSize())
            height = renderer.uiImage?.size.height ?? 0
        }
        return height
    }

    @MainActor
    func testFixedIgnoresTheSetting() {
        let base = drawnHeight(at: .large) { OnymType.fixed(size: 30) }
        let big = drawnHeight(at: .accessibilityExtraExtraExtraLarge) { OnymType.fixed(size: 30) }
        XCTAssertGreaterThan(base, 0, "nothing was drawn")
        XCTAssertEqual(base, big, accuracy: 0.5,
                       "fixed() must not move — it is for artwork, not words")
    }

    @MainActor
    func testFontDoesAnswerTheSetting() {
        let base = drawnHeight(at: .large) { OnymType.font(size: 30) }
        let big = drawnHeight(at: .accessibilityExtraExtraExtraLarge) { OnymType.font(size: 30) }
        XCTAssertGreaterThan(base, 0, "nothing was drawn")
        XCTAssertGreaterThan(big, base * 1.5, "font() did not grow with the setting")
    }

    // MARK: UIKit half

    func testUIKitFacesReadTheSetting() {
        // Asserted rather than assumed: `scaledValue(for:)` ignores
        // `.current`, so it is a fair question whether `scaledFont(for:)`
        // does too. If this fails, uiFont needs `compatibleWith:` the
        // same way `scale()` does — and every UIKit label in the chat
        // thread is stuck at the default size.
        var sizes: [CGFloat] = []
        for category: UIContentSizeCategory in [.large, .accessibilityExtraExtraExtraLarge] {
            at(category) { sizes.append(OnymType.uiFont(size: 12).pointSize) }
        }
        XCTAssertEqual(sizes[0], 12, accuracy: 0.001, "12pt should be 12pt at the default")
        XCTAssertGreaterThan(sizes[1], 24, "uiFont is not reading the setting")
    }

    func testUIKitMonoStaysMono() {
        let mono = OnymType.uiMono(size: 12)
        XCTAssertNotEqual(mono.fontName, UIFont.systemFont(ofSize: 12).fontName,
                          "a fingerprint that stops being monospaced stops lining up")
    }

    func testUIKitFixedDoesNotScale() {
        at(.accessibilityExtraExtraExtraLarge) {
            XCTAssertEqual(OnymType.uiFixed(size: 22).pointSize, 22, accuracy: 0.001)
        }
    }

    func testUIBodyIsTheTextStyleFont() {
        // What `uiBody` must remain, stated as narrowly as it is known.
        //
        // The composer sizes itself to `ceil(font.lineHeight) * 3` and
        // agrees with its own contents when given this font. Given
        // `scaledFont(for: systemFont(17))` — which reports an identical
        // lineHeight, 20.287 — it stands two points taller than three
        // lines of its own text.
        //
        // Why the layout differs when the metrics match is not
        // established here, so this asserts only the thing that was
        // actually measured: the identity of the font. The behaviour it
        // protects is guarded where it lives, by
        // `ChatInputPanelViewTests.test_textGrows_capsAtMaxLineCount` —
        // which is the test that caught the swap in the first place.
        at(.large) {
            XCTAssertEqual(OnymType.uiBody(), UIFont.preferredFont(forTextStyle: .body))
        }
    }
}
