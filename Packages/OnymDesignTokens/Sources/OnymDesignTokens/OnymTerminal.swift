import SwiftUI

// MARK: - Console treatment

/// The dark console block used by the self-host guide, the deploy
/// panel and the relayer setup screens — the places where the app shows
/// a person a command they are meant to run somewhere else.
///
/// Pinned dark in both appearances, deliberately. A terminal that turns
/// white in light mode stops reading as a terminal, and these blocks
/// quote a thing that lives outside the app.
///
/// Adopters who want a different console (a lighter one, or their own
/// brand's) replace these five values; nothing else needs to know.
public enum OnymTerminal {
    /// The console block's surface.
    public static let surface     = hex(0x1B1F24)
    /// One step darker — the code well inside a console block, and the
    /// gradient's far stop.
    public static let surfaceDeep = hex(0x0D1117)
    /// Command text. Phosphor green, high contrast on `surfaceDeep`.
    public static let text        = hex(0xA6FF99)
    /// Near-black, for text set on the phosphor green.
    public static let ink         = hex(0x0A0A0C)

    /// Hairline-equivalent fills for chips and buttons inside a console
    /// block. `OnymTokens.hairline` is tuned for app surfaces and
    /// disappears here.
    public static let overlay       = Color.white.opacity(0.08)
    public static let overlayStrong = Color.white.opacity(0.14)

    private static func hex(_ rgb: UInt32) -> Color {
        Color(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double(rgb         & 0xFF) / 255
        )
    }
}
