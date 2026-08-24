import SwiftUI

// MARK: - Corner radii

/// The corner scale. Nine steps, named for what they wrap rather than
/// what they measure — an adopter changing `inset` to 16 should not
/// have to know it used to be 12.
///
/// Use `OnymRadius.shape(_:)` rather than building a
/// `RoundedRectangle` by hand: it pins `style: .continuous`, which is
/// the curve the design uses everywhere and is easy to forget.
///
/// Artwork geometry is deliberately *not* in here. The crown bar in
/// `OnymGovIcon` rounds at `0.8 * size / 44` because that is a
/// proportion of a drawing, not a UI corner, and it should not move
/// when a theme does.
public enum OnymRadius {
    /// Grouped container on `surface2` — the settings card, the
    /// governance card, anything holding a stack of rows.
    public static let card:    CGFloat = 14
    /// Form field. Shares the card's curve by design, and stays a
    /// separate token so a rounder-field theme is one edit.
    public static let field:   CGFloat = 14
    /// Large standalone padded panel — the deploy panel, the
    /// self-host guide block. One step softer than a card.
    public static let panel:   CGFloat = 18
    /// The square brand tile that reads as an app icon: the About hero,
    /// the recovery key tile. Rounder than a panel because at icon
    /// proportions 18 reads as a flattened square.
    ///
    /// These two sites used to disagree — 26 on a 104pt tile, 22 on a
    /// 72pt one — for the same visual role. They agree now.
    public static let hero:    CGFloat = 22
    /// A surface nested *inside* a card or screen: notice banners,
    /// image thumbnails, member rows.
    public static let inset:   CGFloat = 12
    /// Small inline control or code block.
    public static let control: CGFloat = 10
    /// Compact badge or relay row.
    public static let badge:   CGFloat = 8
    /// The 30×30 leading icon tile on a row.
    public static let tile:    CGFloat = 7
    /// Tiny uppercase status chip — DEFAULT, ACTIVE, VERIFIED.
    public static let chip:    CGFloat = 4

    /// Fully rounded ends. A `Capsule` in SwiftUI terms; expressed as a
    /// radius so it can be passed anywhere the others can.
    public static let pill:    CGFloat = .infinity

    /// A continuous-curve rounded rectangle at the given token.
    ///
    /// `pill` resolves to a `Capsule`, so callers do not have to
    /// special-case it.
    public static func shape(_ radius: CGFloat) -> AnyShape {
        radius == pill
            ? AnyShape(Capsule(style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
