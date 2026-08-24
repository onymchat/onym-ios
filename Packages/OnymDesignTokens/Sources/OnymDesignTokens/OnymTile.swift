import SwiftUI

// MARK: - Icon tile palette

/// The coloured squares at the leading edge of a settings row. Matches
/// the design system's `--on-tile-*` family, and the Apple Settings
/// palette it was drawn from.
///
/// These are pinned rather than theme-adaptive on purpose: the tile is a
/// saturated chip that carries its own contrast, and Settings shows the
/// same hues in both appearances. `OnymTokens.onTile` is the foreground
/// that reads on them.
public enum OnymTile {
    public static let purple = hex(0xA04CE0)
    public static let blue   = hex(0x0A84FF)
    public static let indigo = hex(0x5B5BE2)
    public static let orange = hex(0xFF7A2D)
    public static let green  = hex(0x30B45A)
    public static let gray   = hex(0x8E8E93)
    public static let red    = hex(0xE5392E)
    public static let teal   = hex(0x2BB3CF)
    public static let amber  = hex(0xFF9500)

    private static func hex(_ rgb: UInt32) -> Color {
        Color(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double(rgb         & 0xFF) / 255
        )
    }
}
