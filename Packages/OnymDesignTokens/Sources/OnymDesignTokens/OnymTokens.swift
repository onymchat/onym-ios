import SwiftUI
import UIKit

// MARK: - Tokens

/// Theme-adaptive design tokens for the whole app. Each color resolves
/// to its light or dark variant via the system trait collection — no
/// per-view `@Environment(\.colorScheme)` plumbing required, the
/// `UIColor` dynamic provider does the work.
///
/// Values mirror the `Onym Design System` reference. Pinned RGB values
/// came directly from that source.
///
/// This type is the *substitution surface* for adopters — see this
/// package's README. Every member here is called by name from the app
/// and the UI packages, so a replacement `OnymDesignTokens` module must
/// declare all of them or the app will not compile.
public enum OnymTokens {
    public static let bg              = Color.dynamic(light: hex(0xFFFFFF),  dark: hex(0x000000))
    public static let surface         = Color.dynamic(light: hex(0xF5F5F7),  dark: hex(0x0E0E10))
    public static let surface2        = Color.dynamic(light: hex(0xFFFFFF),  dark: hex(0x17171A))
    public static let surface3        = Color.dynamic(light: hex(0xEBEBEF),  dark: hex(0x1F1F23))
    public static let text            = Color.dynamic(light: hex(0x0A0A0C),  dark: hex(0xF2F2F4))
    public static let text2           = Color.dynamic(light: hex(0x0A0A0C, 0.62), dark: hex(0xF2F2F4, 0.62))
    public static let text3           = Color.dynamic(light: hex(0x0A0A0C, 0.42), dark: hex(0xF2F2F4, 0.40))
    public static let hairline        = Color.dynamic(light: .black.opacity(0.06), dark: .white.opacity(0.07))
    public static let hairlineStrong  = Color.dynamic(light: .black.opacity(0.12), dark: .white.opacity(0.12))
    public static let green           = Color.dynamic(light: hex(0x1FA84A),  dark: hex(0x34C759))
    public static let red             = Color.dynamic(light: hex(0xE5392E),  dark: hex(0xFF453A))
    /// Caution, not failure: something a person should read before
    /// deciding, where `red` would say the decision is already wrong.
    ///
    /// The light value is darker than the system orange it started as.
    /// `#FF9500` on `surface2` is ~2.1:1, which fails WCAG AA for the
    /// caption-sized text this is used on — and it is used on the lines
    /// a founder is most expected to actually read. `#B25E00` clears
    /// 4.5:1. The dark variant already did.
    public static let amber           = Color.dynamic(light: hex(0xB25E00),  dark: hex(0xFF9F0A))

    /// Reads on accent fills (button labels, governance card check
    /// glyphs, success seal). Light → white text on saturated accent;
    /// dark → black text. The same `OnymTokens.onAccent` keeps the
    /// view code theme-agnostic.
    public static let onAccent        = Color.dynamic(light: .white,         dark: .black)

    /// Reads on a saturated tile or gradient fill — the icon tiles, the
    /// recovery key hero, the success seal.
    ///
    /// Distinct from `onAccent`, which flips with the appearance. A
    /// tile carries its own contrast in both themes, so black text on
    /// it in dark mode would be wrong. If a theme's tiles are pale,
    /// this is the one to change.
    public static let onTile          = Color.white

    /// Opaque ground behind a camera viewfinder or a full-screen photo.
    /// Black because a lightbox is black, not because the theme is.
    public static let lightbox        = Color.black

    /// Veil over media — the sheet dim, the swipe-to-dismiss fade, the
    /// plate behind a duration label on a thumbnail. Callers set their
    /// own alpha.
    public static let scrim           = Color.black

    /// `scrim` for the UIKit half of the chat thread, which draws its
    /// media cells in layers rather than views.
    public static let scrimUI         = UIColor.black

    /// Hex literal helper. Optional alpha multiplies sRGB opacity in
    /// place — saves the per-call `.opacity(...)` modifier when
    /// declaring text2 / text3 style tokens.
    private static func hex(_ rgb: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double(rgb         & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension Color {
    /// Build a SwiftUI `Color` that swaps between `light` and `dark`
    /// based on the system trait collection. Backed by `UIColor`'s
    /// dynamic provider so it reacts to user dark-mode toggles
    /// without re-rendering or re-evaluating the calling view.
    public static func dynamic(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
