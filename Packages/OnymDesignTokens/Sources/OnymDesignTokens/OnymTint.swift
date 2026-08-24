import SwiftUI

// MARK: - Tints

/// Pastel fills and the deep inks that read on them: the 52pt gradient
/// tiles at the head of a settings screen, the amber notice banner, the
/// governance badges on the anchors list.
///
/// The set is deliberately asymmetric. Every value here is one the app
/// actually spends — where a hue has no ink, it is because nothing draws
/// ink on it yet, and inventing one would be inventing design.
///
/// ## Known gap
///
/// Most of these are pinned to a light-mode value and do not adapt: an
/// amber notice stays cream on a black screen. That is how the app has
/// always drawn them, and this package preserved it rather than
/// quietly redesigning six screens. Giving them dark variants is a
/// design decision, and a small one — every call site now reads from
/// here, so it is a change to this file alone.
public enum OnymTint {
    // Indigo — the "use an existing contract" tile.
    public static let indigoSoft  = hex(0xE5E5FE)
    public static let indigoSoft2 = hex(0xC7C7F4)
    /// On a 16%-alpha indigo tint.
    public static let indigoInk   = hex(0x3D3DC9)

    // Green — the privacy tile, the democracy badge.
    public static let greenSoft   = hex(0xDFFAEA)
    public static let greenSoft2  = hex(0xB5F0CD)
    /// On a 16%-alpha green tint.
    public static let greenInk    = hex(0x1A8247)
    /// The two-step green ramp on a solid pastel card: title, then body.
    public static let greenInkDeep = hex(0x175E2E)
    public static let greenInkMid  = hex(0x306E47)

    // Orange — the contract-detail tile, the anarchy badge.
    public static let orangeSoft  = hex(0xFEF0E0)
    public static let orangeSoft2 = hex(0xFFE0C0)
    public static let orangeInk   = hex(0xD14A00)

    // Amber — the notice banner: fill, hairline, and the text on it.
    public static let amberSoft   = hex(0xFFF6E5)
    public static let amberSoft2  = hex(0xFFD8A0)
    public static let amberInk    = hex(0x5C3A00)

    // MARK: Adaptive tints
    //
    // These already switched with the appearance before they were
    // tokens; they keep both halves.

    /// The active identity card's halo.
    public static let identityActive  = Color.dynamic(
        light: hex(0xEEF5FF), dark: OnymAccent.blue.color.opacity(0.20))
    public static let identityActive2 = Color.dynamic(
        light: hex(0xD5E8FE), dark: OnymAccent.blue.color.opacity(0.10))

    /// The filled dot on a step indicator.
    public static let stepActive = Color.dynamic(
        light: hex(0xE0EEFE), dark: OnymTile.blue.opacity(0.18))

    /// The far stop of the success seal's gradient. The near stop is
    /// `OnymTokens.green` — the seal used to reach for SwiftUI's
    /// `Color.green` instead, which is the drift this replaced.
    public static let sealTo = hex(0x33C759)

    private static func hex(_ rgb: UInt32) -> Color {
        Color(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double(rgb         & 0xFF) / 255
        )
    }
}
