import SwiftUI
import UIKit
import XCTest
@testable import OnymDesignTokens

/// Shared helpers for reading a token's resolved value in a given
/// appearance, and for the contrast maths the accessibility tests use.
enum Resolved {
    static func rgb(_ color: Color, _ style: UIUserInterfaceStyle) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    /// WCAG 2.1 relative luminance.
    static func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> CGFloat {
        let c = rgb(color, style)
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio between two opaque tokens.
    static func contrast(_ a: Color, on b: Color, _ style: UIUserInterfaceStyle) -> CGFloat {
        let la = luminance(a, style), lb = luminance(b, style)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }
}

/// The completeness check an adopter runs against their own token
/// module before wiring it in.
///
/// The compiler is the real guarantee — 758 call sites will not resolve
/// against an incomplete module. This suite exists so the failure is
/// one readable line rather than several hundred compiler errors, and
/// so a token that is quietly deleted is caught by something other than
/// a screen going blank.
final class TokenContractTests: XCTestCase {

    /// Every colour token, by the name the app calls it.
    private static let colors: [(String, Color)] = [
        ("bg", OnymTokens.bg),
        ("surface", OnymTokens.surface),
        ("surface2", OnymTokens.surface2),
        ("surface3", OnymTokens.surface3),
        ("text", OnymTokens.text),
        ("text2", OnymTokens.text2),
        ("text3", OnymTokens.text3),
        ("hairline", OnymTokens.hairline),
        ("hairlineStrong", OnymTokens.hairlineStrong),
        ("green", OnymTokens.green),
        ("red", OnymTokens.red),
        ("amber", OnymTokens.amber),
        ("onAccent", OnymTokens.onAccent),
        ("onTile", OnymTokens.onTile),
        ("lightbox", OnymTokens.lightbox),
        ("scrim", OnymTokens.scrim),
    ]

    private static let tiles: [(String, Color)] = [
        ("purple", OnymTile.purple), ("blue", OnymTile.blue),
        ("indigo", OnymTile.indigo), ("orange", OnymTile.orange),
        ("green", OnymTile.green), ("gray", OnymTile.gray),
        ("red", OnymTile.red), ("teal", OnymTile.teal),
        ("amber", OnymTile.amber),
    ]

    private static let radii: [(String, CGFloat)] = [
        ("card", OnymRadius.card), ("field", OnymRadius.field),
        ("panel", OnymRadius.panel), ("hero", OnymRadius.hero),
        ("inset", OnymRadius.inset), ("control", OnymRadius.control),
        ("badge", OnymRadius.badge), ("tile", OnymRadius.tile),
        ("chip", OnymRadius.chip), ("pill", OnymRadius.pill),
    ]

    func testEveryColorTokenResolvesInBothAppearances() {
        for (name, color) in Self.colors {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let c = Resolved.rgb(color, style)
                XCTAssertGreaterThan(
                    c.a, 0,
                    "OnymTokens.\(name) is fully transparent in \(style == .light ? "light" : "dark")"
                )
            }
        }
    }

    func testTokenCountsAreStable() {
        // A replacement module that drops a token fails to compile long
        // before it reaches here. These guard the other direction: a
        // token quietly removed from *this* module, where the call sites
        // that used it were removed in the same change.
        XCTAssertEqual(Self.colors.count, 16, "colour token count changed")
        XCTAssertEqual(Self.tiles.count, 9, "OnymTile lost or gained a hue")
        XCTAssertEqual(Self.radii.count, 10, "OnymRadius lost or gained a step")
        XCTAssertEqual(OnymAccent.allCases.count, 6, "OnymAccent case count changed")
    }

    func testSurfacesAreDistinct() {
        // surface / surface2 / surface3 stack on each other. If two
        // collapse to the same value, cards stop reading as cards.
        for style in [UIUserInterfaceStyle.light, .dark] {
            let ls = [OnymTokens.surface, OnymTokens.surface2, OnymTokens.surface3]
                .map { Resolved.luminance($0, style) }
            XCTAssertNotEqual(ls[0], ls[1], accuracy: 0, "surface and surface2 collapsed")
            XCTAssertNotEqual(ls[1], ls[2], accuracy: 0, "surface2 and surface3 collapsed")
        }
    }

    func testAccentsAreDistinctFromEachOther() {
        // forSender spreads people across these six. Two that resolve
        // alike would silently merge two identities' colours.
        for style in [UIUserInterfaceStyle.light, .dark] {
            var seen: [String] = []
            for accent in OnymAccent.allCases {
                let c = Resolved.rgb(accent.color, style)
                let key = String(format: "%.3f,%.3f,%.3f", c.r, c.g, c.b)
                XCTAssertFalse(seen.contains(key), "\(accent.rawValue) duplicates another accent")
                seen.append(key)
            }
        }
    }

    func testRadiusScaleIsOrdered() {
        XCTAssertLessThan(OnymRadius.chip, OnymRadius.tile)
        XCTAssertLessThan(OnymRadius.tile, OnymRadius.badge)
        XCTAssertLessThan(OnymRadius.badge, OnymRadius.control)
        XCTAssertLessThan(OnymRadius.control, OnymRadius.inset)
        XCTAssertLessThan(OnymRadius.inset, OnymRadius.card)
        XCTAssertLessThan(OnymRadius.card, OnymRadius.panel)
        XCTAssertLessThan(OnymRadius.panel, OnymRadius.hero)
        XCTAssertEqual(OnymRadius.card, OnymRadius.field,
                       "field shares the card curve by design; change both or neither")
        XCTAssertEqual(OnymRadius.pill, .infinity)
    }

    func testPillResolvesToACapsule() {
        // Callers pass `pill` through `shape(_:)` and expect fully
        // rounded ends, not a rectangle with an enormous radius.
        let pill = OnymRadius.shape(OnymRadius.pill)
        let box = CGRect(x: 0, y: 0, width: 200, height: 40)
        XCTAssertEqual(pill.path(in: box).boundingRect.height, box.height, accuracy: 0.5)
        XCTAssertEqual(
            pill.path(in: box).boundingRect.width, box.width, accuracy: 0.5,
            "pill should fill its frame; a RoundedRectangle at .infinity would not"
        )
    }

    func testTypeTokensProduceDistinctFaces() {
        // If mono stops being mono, a pubkey stops lining up.
        XCTAssertNotEqual(OnymType.font(size: 14), OnymType.mono(size: 14))
        XCTAssertNotEqual(OnymType.font(size: 14), OnymType.font(size: 14, weight: .bold))
    }
}
