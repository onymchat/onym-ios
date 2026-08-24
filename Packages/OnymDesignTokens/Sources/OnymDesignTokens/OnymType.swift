import SwiftUI
import UIKit

// MARK: - Typography

/// The typeface layer. Two families — text and mono — and nothing else.
///
/// There is deliberately no size scale here. The app spends 31 distinct
/// sizes, which is not a scale but an accretion, and collapsing it is a
/// design decision rather than a packaging one. What this type does is
/// put every font call behind a swappable family, so an adopter
/// shipping their own typeface changes three functions instead of 470
/// call sites.
///
/// ## For adopters
///
/// Replace the bodies, keep the signatures:
///
/// ```swift
/// public static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
///     .custom("Inter", size: scaled(size)).weight(weight)
/// }
/// ```
///
/// Sizes arrive in points from the call site. If your face runs small,
/// scale inside the function rather than asking the app to pass
/// different numbers. Keep the `scaled(_:)` call — dropping it turns
/// Dynamic Type off for the whole app.
///
/// ## Dynamic Type
///
/// `font` and `mono` grow and shrink with the reader's text-size
/// setting. `fixed` does not, and is for glyphs that are drawings
/// rather than words.
///
/// The scaling is applied as a **ratio**, not by handing the size to
/// `UIFontMetrics.scaledFont(for:)`. That method rounds to whole points
/// — 11.5pt becomes 12pt, 13.5pt becomes 14pt — and it does so *at the
/// default text size*, where nothing should move at all. The app spends
/// around sixty half-point sizes, so taking the obvious route would
/// have shipped a visible change to every reader who never touched the
/// setting, in the name of helping the ones who did.
public enum OnymType {
    /// The text face. Everything that is not a key, hash, or relay URL.
    public static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight)
    }

    /// The mono face — relay URLs, pubkeys, recovery words, anything a
    /// person may need to compare character by character.
    public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight, design: .monospaced)
    }

    /// A size that does not answer to the text-size setting.
    ///
    /// For SF Symbols used as artwork rather than type — the 44pt mark
    /// on an onboarding screen, the glyph centred in a 30pt tile. These
    /// sit inside boxes drawn at fixed sizes, and a symbol growing to
    /// 2.8× inside a 30pt square does not help anybody read anything.
    ///
    /// Reach for this only when the glyph is decoration. If it carries
    /// meaning a reader needs, it belongs in `font` and its box needs to
    /// give.
    public static func fixed(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The reader's text-size setting, as a multiplier.
    ///
    /// Keyed to `.body`, so the whole app moves on one curve rather than
    /// each size drifting against its own text style. At the default
    /// setting this is exactly 1 and every size is untouched; at the
    /// largest accessibility size it is about 2.82.
    ///
    /// The trait collection has to be passed in. `scaledValue(for:)`
    /// without one does *not* consult `UITraitCollection.current` — it
    /// answers 1.0 at every setting, which looks like working code and
    /// would have quietly given every reader the default size forever.
    /// `.current` is the right default because SwiftUI sets it while
    /// evaluating a view body, which is the only place these are called
    /// from.
    public static func scale(_ traits: UITraitCollection = .current) -> CGFloat {
        UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: 100, compatibleWith: traits) / 100
    }

    private static func scaled(_ size: CGFloat) -> CGFloat {
        size * scale()
    }
}
