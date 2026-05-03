import SwiftUI
import UIKit

// MARK: - Tokens

/// Theme-adaptive design tokens for the Create Group flow. Each color
/// resolves to its light or dark variant via the system trait
/// collection — no per-view `@Environment(\.colorScheme)` plumbing
/// required, the `UIColor` dynamic provider does the work.
///
/// Mirrors the Claude Designed reference's `THEMES.dark` + `THEMES.light`
/// from `app.jsx`. Pinned RGB values came directly from that source.
enum OnymTokens {
    static let bg              = Color.dynamic(light: hex(0xFFFFFF),  dark: hex(0x000000))
    static let surface         = Color.dynamic(light: hex(0xF5F5F7),  dark: hex(0x0E0E10))
    static let surface2        = Color.dynamic(light: hex(0xFFFFFF),  dark: hex(0x17171A))
    static let surface3        = Color.dynamic(light: hex(0xEBEBEF),  dark: hex(0x1F1F23))
    static let text            = Color.dynamic(light: hex(0x0A0A0C),  dark: hex(0xF2F2F4))
    static let text2           = Color.dynamic(light: hex(0x0A0A0C, 0.62), dark: hex(0xF2F2F4, 0.62))
    static let text3           = Color.dynamic(light: hex(0x0A0A0C, 0.42), dark: hex(0xF2F2F4, 0.40))
    static let hairline        = Color.dynamic(light: .black.opacity(0.06), dark: .white.opacity(0.07))
    static let hairlineStrong  = Color.dynamic(light: .black.opacity(0.12), dark: .white.opacity(0.12))
    static let green           = Color.dynamic(light: hex(0x1FA84A),  dark: hex(0x34C759))
    static let red             = Color.dynamic(light: hex(0xE5392E),  dark: hex(0xFF453A))

    /// Reads on accent fills (button labels, governance card check
    /// glyphs, success seal). Light → white text on saturated accent;
    /// dark → black text. The same `OnymTokens.onAccent` keeps the
    /// view code theme-agnostic.
    static let onAccent        = Color.dynamic(light: .white,         dark: .black)

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
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

// MARK: - Accent palette

enum OnymAccent: String, CaseIterable, Identifiable, Sendable {
    case orange, blue, green, purple, pink, yellow

    var id: String { rawValue }

    /// Per-theme variants from the design. Light variants are
    /// slightly desaturated for legibility on white surfaces; dark
    /// variants are the brighter saturated set that pops on black.
    var color: Color {
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

// MARK: - OnymMark — broken-ring brand logo

/// The Onym brand mark: a broken/segmented ring with two narrow radial
/// gaps. The gaps suggest privacy/anonymity — the identity is whole
/// but never fully closed.
///
/// Implemented as a `Circle().stroke` with a dash pattern of
/// `[46, 4, 46, 4]` (% of circumference), then a `rotationEffect` to
/// align the gaps near 1:30 and 7:30 o'clock. Matches the SVG
/// reference in `app.jsx` (`OnymMark` component, dasharray `46 4 46 4`,
/// dashoffset `-25`).
struct OnymMark: View {
    var size: CGFloat = 32
    var color: Color = OnymTokens.text
    var strokeRatio: CGFloat = 0.16
    var spinning: Bool = false
    var fillOpacity: Double = 0.92

    @State private var rotation: Double = -45  // -45° lands the dash pattern's gaps at 1:00 and 7:00

    var body: some View {
        let stroke = size * strokeRatio
        let radius = (size - stroke) / 2
        let circumference = 2 * .pi * radius
        let arc = circumference * 0.46
        let gap = circumference * 0.04

        Circle()
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: stroke,
                    lineCap: .butt,
                    dash: [arc, gap, arc, gap]
                )
            )
            .opacity(fillOpacity)
            .frame(width: size - stroke, height: size - stroke)
            .padding(stroke / 2)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard spinning else { return }
                withAnimation(.linear(duration: 4.2).repeatForever(autoreverses: false)) {
                    rotation += 360
                }
            }
    }
}

// MARK: - Governance type (UI-side)

/// UI-side mirror of the design's three governance cards. Maps to
/// `SEPGroupType` for the actual chain call. PR-C only enables
/// `.tyranny` — the other two render with a "Soon" label and aren't
/// selectable.
enum OnymUIGovernance: String, CaseIterable, Identifiable, Sendable {
    case tyranny
    case oneOnOne = "dialog"
    case anarchy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tyranny: "Tyranny"
        case .oneOnOne: "1\u{2011}on\u{2011}1"  // non-breaking hyphens
        case .anarchy: "Anarchy"
        }
    }

    var sub: String {
        switch self {
        case .tyranny: "Single admin"
        case .oneOnOne: "Dialog"
        case .anarchy: "Open control"
        }
    }

    var oneLine: String {
        switch self {
        case .tyranny: "You control membership and settings."
        case .oneOnOne: "A private two-person conversation."
        case .anarchy: "Every member has the same control."
        }
    }

    var tooltip: String {
        switch self {
        case .tyranny: "Only the admin can manage this group."
        case .oneOnOne: "Exactly two people. No one else can join."
        case .anarchy: "Anyone can add, remove, or change settings."
        }
    }

    /// True when this governance type is wired through the chain
    /// layer end-to-end. All three currently surfaced types
    /// (Tyranny, 1-on-1, Anarchy) are live.
    var isAvailable: Bool {
        switch self {
        case .tyranny, .oneOnOne, .anarchy: true
        }
    }

    var sepGroupType: SEPGroupType {
        switch self {
        case .tyranny: .tyranny
        case .oneOnOne: .oneOnOne
        case .anarchy: .anarchy
        }
    }
}

// MARK: - Governance icons

/// Small badge icons that go on each governance card. Three distinct
/// silhouettes: crown (admin), facing bubbles (dialog), nodes-in-ring
/// (anarchy). Implemented with SwiftUI `Path`/`Shape` rather than
/// SF symbols because the design uses custom artwork.
struct OnymGovIcon: View {
    let type: OnymUIGovernance
    let accent: Color
    var size: CGFloat = 44
    var dimmed: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(strokeColor, lineWidth: 1.4 * size / 44)
                .opacity(0.5)
            Circle()
                .fill(strokeColor.opacity(0.14))
                .padding(size * 6 / 44)

            switch type {
            case .tyranny: tyrannyMark
            case .oneOnOne: dialogMark
            case .anarchy: anarchyMark
            }
        }
        .frame(width: size, height: size)
    }

    private var strokeColor: Color { dimmed ? OnymTokens.text3 : accent }

    private var tyrannyMark: some View {
        // Crown: filled chevron-y polygon + bar + dot, all in `accent`.
        ZStack {
            Path { path in
                let s = size
                path.move(to: CGPoint(x: s * 13/44, y: s * 24/44))
                path.addLine(to: CGPoint(x: s * 15/44, y: s * 17/44))
                path.addLine(to: CGPoint(x: s * 19/44, y: s * 21/44))
                path.addLine(to: CGPoint(x: s * 22/44, y: s * 15/44))
                path.addLine(to: CGPoint(x: s * 25/44, y: s * 21/44))
                path.addLine(to: CGPoint(x: s * 29/44, y: s * 17/44))
                path.addLine(to: CGPoint(x: s * 31/44, y: s * 24/44))
                path.closeSubpath()
            }
            .fill(strokeColor)

            RoundedRectangle(cornerRadius: 0.8 * size / 44)
                .fill(strokeColor)
                .frame(width: 18 * size / 44, height: 3 * size / 44)
                .position(x: 22 * size / 44, y: 27 * size / 44)

            Circle()
                .fill(dimmed ? OnymTokens.text3 : OnymTokens.onAccent)
                .frame(width: 2.4 * size / 44, height: 2.4 * size / 44)
                .position(x: 22 * size / 44, y: 20 * size / 44)
        }
    }

    private var dialogMark: some View {
        ZStack {
            // Left bubble (filled accent)
            Path { path in
                let s = size
                path.move(to: CGPoint(x: s * 9/44, y: s * 17/44))
                path.addQuadCurve(to: CGPoint(x: s * 12/44, y: s * 14/44), control: CGPoint(x: s * 9/44, y: s * 14/44))
                path.addLine(to: CGPoint(x: s * 19/44, y: s * 14/44))
                path.addQuadCurve(to: CGPoint(x: s * 22/44, y: s * 17/44), control: CGPoint(x: s * 22/44, y: s * 14/44))
                path.addLine(to: CGPoint(x: s * 22/44, y: s * 20/44))
                path.addQuadCurve(to: CGPoint(x: s * 19/44, y: s * 23/44), control: CGPoint(x: s * 22/44, y: s * 23/44))
                path.addLine(to: CGPoint(x: s * 16/44, y: s * 23/44))
                path.addLine(to: CGPoint(x: s * 13/44, y: s * 26/44))
                path.addLine(to: CGPoint(x: s * 13/44, y: s * 23/44))
                path.addLine(to: CGPoint(x: s * 12/44, y: s * 23/44))
                path.addQuadCurve(to: CGPoint(x: s * 9/44, y: s * 20/44), control: CGPoint(x: s * 9/44, y: s * 23/44))
                path.closeSubpath()
            }
            .fill(strokeColor)

            // Right bubble (translucent accent)
            Path { path in
                let s = size
                path.move(to: CGPoint(x: s * 35/44, y: s * 22/44))
                path.addQuadCurve(to: CGPoint(x: s * 32/44, y: s * 19/44), control: CGPoint(x: s * 35/44, y: s * 19/44))
                path.addLine(to: CGPoint(x: s * 25/44, y: s * 19/44))
                path.addQuadCurve(to: CGPoint(x: s * 22/44, y: s * 22/44), control: CGPoint(x: s * 22/44, y: s * 19/44))
                path.addLine(to: CGPoint(x: s * 22/44, y: s * 25/44))
                path.addQuadCurve(to: CGPoint(x: s * 25/44, y: s * 28/44), control: CGPoint(x: s * 22/44, y: s * 28/44))
                path.addLine(to: CGPoint(x: s * 28/44, y: s * 28/44))
                path.addLine(to: CGPoint(x: s * 31/44, y: s * 31/44))
                path.addLine(to: CGPoint(x: s * 31/44, y: s * 28/44))
                path.addLine(to: CGPoint(x: s * 32/44, y: s * 28/44))
                path.addQuadCurve(to: CGPoint(x: s * 35/44, y: s * 25/44), control: CGPoint(x: s * 35/44, y: s * 28/44))
                path.closeSubpath()
            }
            .fill(strokeColor.opacity(0.55))
        }
    }

    private var anarchyMark: some View {
        // Five nodes in a ring with light edges between every pair.
        let count = 5
        let nodes: [CGPoint] = (0..<count).map { i in
            let a = (Double(i) / Double(count)) * .pi * 2 - .pi / 2
            return CGPoint(
                x: 22 * size / 44 + cos(a) * 10 * size / 44,
                y: 22 * size / 44 + sin(a) * 10 * size / 44
            )
        }
        return ZStack {
            // Edges
            Path { path in
                for i in 0..<count {
                    for j in (i + 1)..<count {
                        path.move(to: nodes[i])
                        path.addLine(to: nodes[j])
                    }
                }
            }
            .stroke(strokeColor.opacity(0.45), lineWidth: 0.9 * size / 44)

            // Nodes
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(strokeColor)
                    .frame(width: 5.2 * size / 44, height: 5.2 * size / 44)
                    .position(nodes[i])
            }
        }
    }
}

// MARK: - Group avatar (Onym mark as upload placeholder)

/// Avatar slot. In this prototype the user never uploads an image, so
/// the slot always shows the brand mark — same behaviour as the
/// design's `GroupAvatar` after the `forceInitials` refactor.
struct OnymGroupAvatar: View {
    var size: CGFloat = 96
    var accent: Color = OnymAccent.blue.color
    var ringPulse: Bool = false
    var spinning: Bool = false
    /// When `true` the mark renders in the accent colour rather than
    /// the neutral text colour — used on the Creating screen.
    var brand: Bool = false

    var body: some View {
        ZStack {
            if ringPulse {
                Circle()
                    .stroke(accent, lineWidth: 1.5)
                    .padding(-8)
                    .modifier(PulseModifier())
            }
            OnymMark(
                size: size,
                color: brand ? accent : OnymTokens.text,
                spinning: spinning,
                fillOpacity: brand ? 1.0 : 0.92
            )
        }
        .frame(width: size, height: size)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .opacity(animating ? 0.55 : 0.35)
            .scaleEffect(animating ? 1.06 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    animating = true
                }
            }
    }
}
