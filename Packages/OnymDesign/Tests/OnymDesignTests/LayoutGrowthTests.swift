import SwiftUI
import UIKit
import XCTest
@testable import OnymDesign

/// Whether the shared components actually grow when the reader asks
/// them to.
///
/// This began as a throwaway harness for looking at the layout pass, and
/// earned a place by finding four defects that counting call sites had
/// pointed at none of: glyphs overflowing fixed boxes, buttons pinned
/// around labels that outgrew them, tiles stranded at 30pt beside 46pt
/// text, and a title breaking mid-word into "Setting" over a lonely "s".
///
/// On device the system sets both the UIKit trait collection — which the
/// fonts read — and the SwiftUI environment, which the line limits read.
/// A test has to set both, or the two disagree and it measures a state
/// no reader is ever in.
@MainActor
final class LayoutGrowthTests: XCTestCase {

    private struct Sample: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                LargeTitle("Settings")
                SectionLabel("TRANSPORT")
                Card {
                    Row(title: "Relayers",
                        subtitle: "wss://relay.onym.app",
                        subtitleMono: true) {
                        IconTile(symbol: "antenna.radiowaves.left.and.right",
                                 bg: OnymTile.indigo)
                    }
                    Row(title: "Notifications and alerts",
                        subtitle: "Wake this device when a message arrives",
                        last: true) {
                        IconTile(symbol: "bell.fill", bg: OnymTile.red)
                    }
                }
                Footnote("Published by the onym-relayer project. Tap to add.")
            }
            .padding(.vertical, 12)
            .background(OnymTokens.surface)
        }
    }

    /// Renders `content` as the system would at `category`, and returns
    /// the size it settled on.
    private func renderedSize<V: View>(
        at category: UIContentSizeCategory,
        width: CGFloat = 390,
        @ViewBuilder _ content: @escaping () -> V
    ) -> CGSize {
        var size = CGSize.zero
        UITraitCollection(preferredContentSizeCategory: category).performAsCurrent {
            let renderer = ImageRenderer(
                content: content()
                    .environment(\.dynamicTypeSize, Self.typeSize(for: category))
                    .frame(width: width)
            )
            size = renderer.uiImage?.size ?? .zero
        }
        return size
    }

    private static func typeSize(for category: UIContentSizeCategory) -> DynamicTypeSize {
        category == .accessibilityExtraExtraExtraLarge ? .accessibility5 : .large
    }

    func testTheSettingsScreenGrowsForTheReader() {
        let base = renderedSize(at: .large) { Sample() }
        let big = renderedSize(at: .accessibilityExtraExtraExtraLarge) { Sample() }

        XCTAssertGreaterThan(base.height, 0, "nothing rendered")
        XCTAssertGreaterThan(
            big.height, base.height * 1.8,
            "the screen barely grew — something is still pinning the layout"
        )
        // Width is fixed by the frame; if it exceeds it, something is
        // pushing out sideways rather than wrapping.
        XCTAssertEqual(big.width, base.width, accuracy: 1,
                       "content escaped its width instead of wrapping")
    }

    func testIconTileGrowsButStaysATile() {
        let base = renderedSize(at: .large, width: 100) {
            IconTile(symbol: "bell.fill", bg: OnymTile.red)
        }
        let big = renderedSize(at: .accessibilityExtraExtraExtraLarge, width: 100) {
            IconTile(symbol: "bell.fill", bg: OnymTile.red)
        }
        XCTAssertGreaterThan(big.height, base.height,
                             "a tile stranded at 30pt beside 46pt text reads as a bug")
        XCTAssertLessThanOrEqual(
            big.height, 47,
            "the cap is what keeps this a tile rather than 85pt of decoration"
        )
    }

    // Not covered here: that `LargeTitle` shrinks a long single word
    // rather than breaking it mid-word into "Setting" over a lonely "s".
    //
    // It was tried. Because `minimumScaleFactor` shrinks the wrapped
    // case too, a one-line title and a two-line one land close enough in
    // height that any threshold separating them is a number picked to
    // make the test pass rather than a property being asserted. The
    // behaviour is real and was confirmed by looking at the render; a
    // brittle test that agrees with it today is worth less than this
    // note. Snapshot testing would settle it properly, and the repo has
    // no snapshot harness to hang it on.
}
