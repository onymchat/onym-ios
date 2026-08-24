import SwiftUI

// MARK: - Typography

/// The typeface layer. Two families — text and mono — and nothing else.
///
/// There is deliberately no size scale here. The app currently spends
/// 31 distinct sizes, which is not a scale but an accretion, and
/// collapsing it is a design decision rather than a packaging one.
/// What this type does is put every font call behind a swappable
/// family, so an adopter shipping their own typeface changes two
/// functions instead of 465 call sites.
///
/// ## For adopters
///
/// Replace the bodies, keep the signatures:
///
/// ```swift
/// public static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
///     .custom("Inter", size: size).weight(weight)
/// }
/// ```
///
/// Sizes arrive in points from the call site. If your face runs small,
/// scale inside the function rather than asking the app to pass
/// different numbers.
///
/// ## Dynamic Type
///
/// These return fixed-size fonts, matching the behaviour of the
/// `.system(size:)` calls they replaced — this package changed the
/// seam, not the sizing policy. Honouring Dynamic Type means routing
/// through `Font.custom(_:size:relativeTo:)` here *and* auditing the
/// layouts that assume fixed metrics, which is its own piece of work.
public enum OnymType {
    /// The text face. Everything that is not a key, hash, or relay URL.
    public static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The mono face — relay URLs, pubkeys, recovery words, anything a
    /// person may need to compare character by character.
    public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
