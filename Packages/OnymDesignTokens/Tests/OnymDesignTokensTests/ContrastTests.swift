import SwiftUI
import UIKit
import XCTest
@testable import OnymDesignTokens

/// Contrast floors the palette has to clear.
///
/// These exist because the amber token was once the system orange, and
/// `#FF9500` on `surface2` measures about 2.1:1 — it failed WCAG AA at
/// the caption size it is used on, which is the size a founder is most
/// expected to actually read. It was fixed by hand. A resync from the
/// design system, or an adopter copying this package and "restoring"
/// the system colour, would put it straight back.
///
/// A theme that cannot clear these is not a theme, it is an
/// accessibility regression, and it should fail here rather than in
/// review.
final class ContrastTests: XCTestCase {

    /// WCAG AA for normal-size body text.
    private let aa: CGFloat = 4.5
    /// WCAG AA for large text (18pt+, or 14pt+ bold).
    private let aaLarge: CGFloat = 3.0

    private func assertContrast(
        _ fg: Color, on bg: Color, _ style: UIUserInterfaceStyle,
        atLeast floor: CGFloat, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ratio = Resolved.contrast(fg, on: bg, style)
        XCTAssertGreaterThanOrEqual(
            ratio, floor,
            String(format: "%@ in %@ is %.2f:1, needs %.1f:1",
                   label, style == .light ? "light" : "dark", ratio, floor),
            file: file, line: line
        )
    }

    func testPrimaryTextClearsAAOnEverySurface() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (name, surface) in [("bg", OnymTokens.bg),
                                    ("surface", OnymTokens.surface),
                                    ("surface2", OnymTokens.surface2),
                                    ("surface3", OnymTokens.surface3)] {
                assertContrast(OnymTokens.text, on: surface, style,
                               atLeast: aa, "text on \(name)")
            }
        }
    }

    func testAmberClearsAAOnCardSurface() {
        // The whole reason this token diverges from the design system.
        for style in [UIUserInterfaceStyle.light, .dark] {
            assertContrast(OnymTokens.amber, on: OnymTokens.surface2, style,
                           atLeast: aa, "amber on surface2")
        }
    }

    func testSemanticColorsClearAAOnCardSurface() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            assertContrast(OnymTokens.red, on: OnymTokens.surface2, style,
                           atLeast: aaLarge, "red on surface2")
            assertContrast(OnymTokens.green, on: OnymTokens.surface2, style,
                           atLeast: aaLarge, "green on surface2")
        }
    }

    /// White glyphs on the icon tiles, measured.
    ///
    /// Four of the nine sit below WCAG 1.4.11's 3:1 for non-text
    /// contrast — amber at 2.20, teal at 2.48, orange at 2.60, green at
    /// 2.69. They are Apple's Settings palette, drawn the way Settings
    /// draws it, and 1.4.11 does not bind here: the glyph is decorative
    /// and every tile sits beside a `Row` whose title carries the same
    /// meaning in text. Nothing is only knowable from the tile.
    ///
    /// So this is a regression guard rather than a conformance claim.
    /// The floor catches a theme that pushes a tile to genuinely
    /// illegible; it does not pretend the current palette clears AA.
    /// If the glyph ever becomes the only cue for something, this test
    /// should be raised to `aaLarge` and the palette darkened to meet it.
    func testOnTileStaysLegibleOnEveryTile() {
        let floor: CGFloat = 2.1
        for (name, tile) in [("purple", OnymTile.purple), ("blue", OnymTile.blue),
                             ("indigo", OnymTile.indigo), ("orange", OnymTile.orange),
                             ("green", OnymTile.green), ("gray", OnymTile.gray),
                             ("red", OnymTile.red), ("teal", OnymTile.teal),
                             ("amber", OnymTile.amber)] {
            assertContrast(OnymTokens.onTile, on: tile, .light,
                           atLeast: floor, "onTile on \(name) tile")
        }
    }

    /// The tiles that *do* clear 3:1 must not quietly fall below it.
    func testStrongTilesKeepNonTextContrast() {
        for (name, tile) in [("purple", OnymTile.purple), ("indigo", OnymTile.indigo),
                             ("red", OnymTile.red), ("gray", OnymTile.gray),
                             ("blue", OnymTile.blue)] {
            assertContrast(OnymTokens.onTile, on: tile, .light,
                           atLeast: aaLarge, "onTile on \(name) tile")
        }
    }

    func testConsoleTextReadsOnConsoleSurface() {
        assertContrast(OnymTerminal.text, on: OnymTerminal.surfaceDeep, .light,
                       atLeast: aa, "console text on console surface")
        assertContrast(OnymTerminal.ink, on: OnymTerminal.text, .light,
                       atLeast: aa, "console ink on phosphor")
    }

    func testTintInksReadOnTheirFills() {
        assertContrast(OnymTint.amberInk, on: OnymTint.amberSoft, .light,
                       atLeast: aa, "amber ink on amber fill")
        assertContrast(OnymTint.greenInkDeep, on: OnymTint.greenSoft, .light,
                       atLeast: aa, "green ink on green fill")
        assertContrast(OnymTint.orangeInk, on: OnymTint.orangeSoft, .light,
                       atLeast: aa, "orange ink on orange fill")
        assertContrast(OnymTint.indigoInk, on: OnymTint.indigoSoft, .light,
                       atLeast: aa, "indigo ink on indigo fill")
    }
}
