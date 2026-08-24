import SwiftUI

// MARK: - Accent palette

/// The identity accent palette. One accent belongs to each chat sender
/// and is used consistently across their bubbles and avatar.
///
/// The *case set* is part of the contract, not a token: `OnymDesign`
/// maps a sender's pubkey onto `allCases`, so adopters recolor the
/// cases but should not add or remove them — changing the count
/// reshuffles every existing sender's color.
public enum OnymAccent: String, CaseIterable, Identifiable, Sendable {
    case orange, blue, green, purple, pink, yellow

    public var id: String { rawValue }

    /// Per-theme variants from the design. Light variants are
    /// slightly desaturated for legibility on white surfaces; dark
    /// variants are the brighter saturated set that pops on black.
    public var color: Color {
        switch self {
        case .orange: Color.dynamic(light: rgb(0xE85F2A), dark: rgb(0xFF7A45))
        case .blue:   Color.dynamic(light: rgb(0x1F86E0), dark: rgb(0x3FA8FF))
        case .green:  Color.dynamic(light: rgb(0x1FA84A), dark: rgb(0x3DD66E))
        case .purple: Color.dynamic(light: rgb(0x8B4DEB), dark: rgb(0xB278FF))
        case .pink:   Color.dynamic(light: rgb(0xE03253), dark: rgb(0xFF4D6D))
        case .yellow: Color.dynamic(light: rgb(0xD9A400), dark: rgb(0xFFC93C))
        }
    }

    private func rgb(_ hex: UInt32) -> Color {
        Color(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex         & 0xFF) / 255
        )
    }
}
